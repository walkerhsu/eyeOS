"""Runs the agent through the Codex CLI (`codex exec --json`).

eyeOS tools reach Codex via mcp_bridge.py, a stdio MCP server Codex spawns, which calls back into this process over a
loopback WebSocket guarded by a random token. Codex runs with --ignore-user-config (the user's own MCP servers and
plugins stay out) in a read-only sandbox, so the eyeOS tools are its only way to act.
"""
import asyncio
import base64
import json
import secrets
import sys
import tempfile
import traceback
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from websockets.exceptions import ConnectionClosed

BRIDGE = str(Path(__file__).with_name("mcp_bridge.py"))
OFF_FEATURES = ("apps", "browser_use", "browser_use_external", "computer_use")


def _toml(v):
    return json.dumps(v)  # JSON strings and string arrays are valid TOML


class Codex:
    def __init__(self, cli):
        self.cli = cli
        self.server = None
        self.port = None
        self.token = secrets.token_hex(16)
        self.runs = {}  # run key -> (tools, call)

    async def _serve(self, ws):
        q = parse_qs(urlparse(ws.request.path).query)
        run = self.runs.get(q.get("run", [None])[0])
        if q.get("token", [None])[0] != self.token or run is None:
            await ws.close(4401, "bad token")
            return
        tools, call = run
        try:
            await self._answer(ws, tools, call)
        except ConnectionClosed:  # Codex kills the bridge when the turn ends
            pass

    async def _answer(self, ws, tools, call):
        async for raw in ws:
            m = json.loads(raw)
            if m.get("op") == "list":
                out = {"tools": tools}
            else:
                try:
                    out = {"result": await call(m.get("name"), m.get("args") or {})}
                except Exception as e:  # noqa: BLE001
                    traceback.print_exc()
                    out = {"result": {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True}}
            await ws.send(json.dumps({"id": m.get("id"), **out}, default=str))

    async def _bridge_url(self, key):
        if self.server is None:
            import websockets
            self.server = await websockets.serve(self._serve, "127.0.0.1", 0, max_size=2 ** 23)
            self.port = self.server.sockets[0].getsockname()[1]
        return f"ws://127.0.0.1:{self.port}/?token={self.token}&run={key}"

    async def run(self, system, content, tools=None, call=None, model=None, timeout=240):
        """Yields ("text", s), ("thinking", s) and ("usage", input_tokens, output_tokens); raises on failure.

        `content` uses Anthropic blocks (text / base64 image); images become `-i` attachments.
        """
        key = secrets.token_hex(8)
        with tempfile.TemporaryDirectory(prefix="eyeos-codex-") as tmp:
            texts, images, label = [system], [], None
            for b in content:
                if b["type"] == "text":
                    texts.append(b["text"])
                    label = b["text"]
                elif b["type"] == "image":
                    path = Path(tmp) / f"{len(images)}-{label or 'image'}.jpg"
                    path.write_bytes(base64.b64decode(b["source"]["data"]))
                    images.append(str(path))
            if images:
                texts.insert(1, f"Attached images, in order: {', '.join(Path(i).stem.split('-', 1)[1] for i in images)}.")
            args = [self.cli, "exec", "-", "--json", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral",
                    "-s", "read-only", "-C", tmp, "-c", 'model_reasoning_effort="low"', "-c", 'model_reasoning_summary="auto"']
            for f in OFF_FEATURES:
                args += ["-c", f"features.{f}=false"]
            if tools:
                self.runs[key] = (tools, call)
                url = await self._bridge_url(key)
                args += ["-c", f"mcp_servers.eyeos.command={_toml(sys.executable)}",
                         "-c", f"mcp_servers.eyeos.args={_toml(['-I', BRIDGE, url])}",
                         "-c", 'mcp_servers.eyeos.default_tools_approval_mode="approve"']
            if model:
                args += ["-m", model]
            for i in images:
                args += ["-i", i]
            proc = await asyncio.create_subprocess_exec(*args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                                                        stderr=asyncio.subprocess.PIPE, limit=2 ** 24)
            err_tail = []

            async def drain():
                async for line in proc.stderr:
                    err_tail.append(line.decode(errors="replace").rstrip())
                    del err_tail[:-20]

            drainer = asyncio.create_task(drain())
            try:
                proc.stdin.write("\n\n".join(texts).encode())
                await proc.stdin.drain()
                proc.stdin.close()
                failed = None
                async with asyncio.timeout(timeout):
                    async for raw in proc.stdout:
                        try:
                            ev = json.loads(raw)
                        except ValueError:
                            continue
                        t, item = ev.get("type"), ev.get("item") or {}
                        if t == "item.completed" and item.get("type") == "agent_message" and item.get("text"):
                            yield ("text", item["text"])
                        elif t == "item.completed" and item.get("type") == "reasoning" and item.get("text"):
                            yield ("thinking", item["text"])
                        elif t == "turn.completed":
                            failed = None  # earlier "error" events were transient (e.g. reconnects)
                            u = ev.get("usage") or {}
                            yield ("usage", u.get("input_tokens") or 0, u.get("output_tokens") or 0)
                        elif t == "turn.failed":
                            failed = (ev.get("error") or {}).get("message") or "turn failed"
                        elif t == "error":
                            failed = ev.get("message") or failed
                    code = await proc.wait()
                if failed or code:
                    raise RuntimeError(failed or f"codex exited {code}: " + " | ".join(err_tail[-3:]))
            finally:
                self.runs.pop(key, None)
                if proc.returncode is None:
                    proc.kill()
                    await proc.wait()
                drainer.cancel()

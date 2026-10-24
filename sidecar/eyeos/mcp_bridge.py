"""Stdio MCP server that the Codex CLI spawns for one agent run.

It forwards tools/list and tools/call to the sidecar (codex.py) over a local WebSocket, so every Codex tool call goes
through the same approval gate as Claude's. Run as a script (`python -I mcp_bridge.py WS_URL`): stdlib + websockets only.
"""
import json
import sys

from websockets.sync.client import connect


def main(url):
    ws = None
    seq = 0

    def ask(msg):
        nonlocal ws, seq
        ws = ws or connect(url, max_size=None)
        seq += 1
        ws.send(json.dumps({**msg, "id": seq}))
        return json.loads(ws.recv())

    def reply(mid, result=None, error=None):
        out = {"jsonrpc": "2.0", "id": mid}
        out.update({"error": error} if error else {"result": result})
        sys.stdout.write(json.dumps(out) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        if not line.strip():
            continue
        m = json.loads(line)
        mid, method, params = m.get("id"), m.get("method"), m.get("params") or {}
        if mid is None:  # notifications need no answer
            continue
        try:
            if method == "initialize":
                reply(mid, {"protocolVersion": params.get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
                            "serverInfo": {"name": "eyeos", "version": "1"}})
            elif method == "tools/list":
                reply(mid, {"tools": ask({"op": "list"})["tools"]})
            elif method == "tools/call":
                reply(mid, ask({"op": "call", "name": params.get("name"), "args": params.get("arguments") or {}})["result"])
            elif method == "ping":
                reply(mid, {})
            else:
                reply(mid, error={"code": -32601, "message": f"method not found: {method}"})
        except Exception as e:  # noqa: BLE001 - report to Codex instead of dying mid-run
            reply(mid, error={"code": -32603, "message": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main(sys.argv[1])

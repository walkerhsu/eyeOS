import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from eyeos import openai_compat as OA


def serve(replies):
    """A fake OpenAI-compatible server: answers each POST with the next reply and records what it was sent."""
    seen = []

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            seen.append({"path": self.path, "auth": self.headers.get("Authorization"),
                         "body": json.loads(self.rfile.read(int(self.headers["Content-Length"])))})
            self._json(replies.pop(0))

        def do_GET(self):
            self._json({"data": [{"id": "qwen3"}, {"id": "gemma3"}]})

        def _json(self, d):
            out = json.dumps(d).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_port}/v1", seen, srv


def msg(content=None, tool_calls=None, **extra):
    return {"choices": [{"message": {"role": "assistant", "content": content, "tool_calls": tool_calls, **extra}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 3}}


TOOLS = [{"name": "remind_to_blink", "description": "pulse", "inputSchema": {"type": "object", "properties": {}}}]


def test_tool_loop_runs_tools_and_feeds_results_back():
    url, seen, srv = serve([
        msg("<think>low blink rate</think>Blink cue first.",
            [{"id": "c1", "type": "function", "function": {"name": "remind_to_blink", "arguments": '{"count": 2}'}}]),
        msg("Done."),
    ])
    calls = []

    async def call(name, args):
        calls.append((name, args))
        return {"content": [{"type": "text", "text": "pulse shown"}]}

    async def go():
        return [ev async for ev in OA.run(url, "qwen3", "sys", "ctx", TOOLS, call, key="k")]
    try:
        evs = asyncio.run(go())
    finally:
        srv.shutdown()
    assert calls == [("remind_to_blink", {"count": 2})]
    assert ("thinking", "low blink rate") in evs and ("text", "Blink cue first.") in evs and ("text", "Done.") in evs
    assert sum(e[1] for e in evs if e[0] == "usage") == 20
    assert seen[0]["auth"] == "Bearer k" and seen[0]["path"] == "/v1/chat/completions"
    assert seen[0]["body"]["tools"][0]["function"]["name"] == "remind_to_blink"
    assert seen[1]["body"]["messages"][-1] == {"role": "tool", "tool_call_id": "c1", "content": "pulse shown"}


def test_tool_rounds_stop_at_max_turns():
    loop_call = [{"id": "c", "type": "function", "function": {"name": "remind_to_blink", "arguments": "{}"}}]
    url, seen, srv = serve([msg(None, loop_call) for _ in range(3)])
    n = []

    async def call(name, args):
        n.append(name)
        return {"content": [{"type": "text", "text": "ok"}]}

    async def go():
        return [ev async for ev in OA.run(url, "m", "sys", "ctx", TOOLS, call, max_turns=2)]
    try:
        asyncio.run(go())
    finally:
        srv.shutdown()
    assert len(n) == 2 and len(seen) == 3 and seen[0]["auth"] is None


def test_bad_tool_arguments_go_back_to_the_model_as_an_error():
    url, seen, srv = serve([
        msg(None, [{"id": "c1", "type": "function", "function": {"name": "remind_to_blink", "arguments": "{oops"}}]),
        msg("ok"),
    ])

    async def call(name, args):
        raise AssertionError("must not run")

    async def go():
        return [ev async for ev in OA.run(url, "m", "sys", "ctx", TOOLS, call)]
    try:
        asyncio.run(go())
    finally:
        srv.shutdown()
    assert seen[1]["body"]["messages"][-1]["content"].startswith("error:")


def test_vision_ask_sends_data_url_and_strips_reasoning():
    url, seen, srv = serve([msg('{"activity": "coding"}', reasoning_content="hmm")])
    try:
        out = asyncio.run(OA.ask(url, "gemma3", "what's up", ["QUJD"]))
        models = asyncio.run(OA.models(url))
    finally:
        srv.shutdown()
    assert out == '{"activity": "coding"}'
    part = seen[0]["body"]["messages"][0]["content"][1]
    assert part == {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}}
    assert models == ["gemma3", "qwen3"]


def test_on_this_mac():
    assert OA.on_this_mac("http://127.0.0.1:1234/v1") and OA.on_this_mac("http://localhost:8080/v1")
    assert OA.on_this_mac("http://[::1]:8000/v1")
    assert not OA.on_this_mac("http://192.168.1.20:8000/v1") and not OA.on_this_mac("https://api.openai.com/v1")

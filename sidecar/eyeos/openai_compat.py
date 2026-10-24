"""Any OpenAI-compatible /chat/completions endpoint (LM Studio, llama.cpp, vLLM, mlx_lm, Ollama's /v1, or a hosted
API), used by the agent (provider "openai") and by the conductor's screen check (vision backend "openai").

Stdlib only. Tools go through Chat Completions function calling. Reasoning comes back as `reasoning_content` /
`reasoning`, or as <think>…</think> at the start of the content (Qwen 3, DeepSeek R1 and other local models).
Keys come from the app's Keychain through the environment, one per role, so the agent's key never goes to the
vision server or the other way round.
"""
import asyncio
import ipaddress
import json
import re
import traceback
import urllib.error
import urllib.request
from urllib.parse import urlparse

AGENT_KEY_ENV = "EYEOS_AGENT_API_KEY"
VISION_KEY_ENV = "EYEOS_VISION_API_KEY"
THINK = re.compile(r"^\s*<think>(.*?)</think>\s*", re.S)


def on_this_mac(url):
    """True when the endpoint is loopback, i.e. what it's sent never leaves the Mac."""
    host = urlparse(url).hostname or ""
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _request(base_url, path, key, body=None, timeout=180):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(base_url.rstrip("/") + path, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{e.code} from {base_url}: {e.read(300).decode(errors='replace')}") from e


async def models(base_url, key=None):
    """The model ids the server lists (GET /models)."""
    r = await asyncio.to_thread(_request, base_url, "/models", key, None, 10)
    return sorted(m["id"] for m in r.get("data") or [] if isinstance(m, dict) and m.get("id"))


async def chat(base_url, model, messages, tools=None, key=None, timeout=180, **extra):
    """One completion. Returns (assistant message, usage)."""
    body = {"model": model, "messages": messages, "stream": False, **extra}
    if tools:
        body["tools"] = tools
    r = await asyncio.to_thread(_request, base_url, "/chat/completions", key, body, timeout)
    if r.get("error") or not r.get("choices"):  # some servers answer 200 with an error body
        raise RuntimeError(str(r.get("error") or "no choices in reply")[:300])
    return r["choices"][0].get("message") or {}, r.get("usage") or {}


def split_thinking(msg):
    """(thinking, text) of an assistant message."""
    text = msg.get("content") or ""
    if isinstance(text, list):
        text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
    thinking = msg.get("reasoning_content") or msg.get("reasoning") or ""
    m = THINK.match(text)
    if m:
        thinking, text = thinking or m.group(1), text[m.end():]
    return thinking.strip(), text.strip()


def _args(raw):
    args = json.loads(raw) if isinstance(raw, str) and raw.strip() else raw or {}
    if not isinstance(args, dict):
        raise ValueError("arguments must be a JSON object")
    return args


async def run(base_url, model, system, text, tools=(), call=None, key=None, max_turns=6, timeout=180):
    """Yields ("text", s), ("thinking", s) and ("usage", input_tokens, output_tokens), like Codex.run; raises on failure.

    `tools` are MCP-style {name, description, inputSchema}; `call(name, args)` returns MCP-style content. At most
    `max_turns` rounds of tool calls run; tool calls after that are ignored.
    """
    fns = [{"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["inputSchema"]}}
           for t in tools]
    messages = [{"role": "system", "content": system}, {"role": "user", "content": text}]
    for turn in range(max_turns + 1):
        msg, u = await chat(base_url, model, messages, fns, key, timeout, temperature=0.2)
        yield ("usage", u.get("prompt_tokens") or 0, u.get("completion_tokens") or 0)
        thinking, reply = split_thinking(msg)
        if thinking:
            yield ("thinking", thinking)
        if reply:
            yield ("text", reply)
        calls = msg.get("tool_calls") or []
        if not calls or call is None or turn == max_turns:
            return
        messages.append({"role": "assistant", "content": msg.get("content"), "tool_calls": calls})
        for c in calls:
            fn = c.get("function") or {}
            try:
                out = await call(fn.get("name"), _args(fn.get("arguments")))
                result = "\n".join(b["text"] if b["type"] == "text" else f"[{b['type']} not shown]" for b in out["content"])
            except Exception as e:  # noqa: BLE001 - the model sees the error and can recover
                traceback.print_exc()
                result = f"error: {e}"
            messages.append({"role": "tool", "tool_call_id": c.get("id") or "", "content": result})


async def complete(base_url, model, system, text, key=None, timeout=180):
    """Single-shot text completion (no tools)."""
    out = [v[0] async for kind, *v in run(base_url, model, system, text, key=key, timeout=timeout) if kind == "text"]
    return (out[-1] if out else "").strip()


async def ask(base_url, model, prompt, images=(), key=None, timeout=180):
    """One user turn with optional base64 JPEGs. Returns the reply text, without any reasoning."""
    content = [{"type": "text", "text": prompt}] + [
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b}} for b in images]
    msg, _ = await chat(base_url, model, [{"role": "user", "content": content if images else prompt}], key=key,
                        timeout=timeout, temperature=0.1)
    return split_thinking(msg)[1]

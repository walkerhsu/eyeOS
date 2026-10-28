"""The conductor: an on-device vision model that looks at the screen every 30 s and tells eyeOS what's going on.

Each check combines one screenshot with the eye/posture metrics and the previous check's text, and returns what the
user is doing, the situation (deep work, meeting, casual...), how deep the focus is and how interruptible they are.
eyeOS uses that to enter/leave Zen and to decide whether a nudge should go out now or wait.

Privacy: the screenshot is captured straight into memory, never written to disk, sent only to the vision model
(Ollama on 127.0.0.1, or the OpenAI-compatible server the user picked; state() flags one that isn't on this Mac)
and wiped as soon as the check is done. The cloud agent only ever gets the text below,
which the prompt keeps free of names, numbers and quoted private text. Continuity between checks comes from the
previous check's text, not from keeping old images.
"""
import asyncio
import base64
import collections
import json
import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

from . import openai_compat as OA
from .tools import system as S

OLLAMA = "http://127.0.0.1:11434"
OLLAMA_DIRS = ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Ollama.app/Contents/Resources",
               os.path.expanduser("~/Applications/Ollama.app/Contents/Resources")]

PROMPT = """You are the conductor of eyeOS, an eye-comfort assistant on this Mac. You see a screenshot of the user's
screen right now, plus their eye/posture metrics and what you concluded 30 seconds ago. Decide what is going on.
Privacy: no names, emails, numbers, URLs or quoted private text in your answer.

Reply as JSON with keys:
activity (<=12 words, e.g. "editing Python code in VS Code"),
content_type (one of: coding, reading, writing, video, design, chat, meeting, spreadsheet, browsing, gaming, other),
situation (one of: deep_work, meeting, reading, casual, entertainment, idle),
focus (deep, light or none: deep = sustained concentrated work where an interruption would cost a lot),
interruptibility (0.0-1.0: 0 = never interrupt now (meeting, presenting, mid-flow), 1 = a perfect moment (idle,
  casual browsing, just finished something)),
text_size (small, normal, large),
background (light, dark, mixed),
long_reading (true if reading a long article or document),
voice_task (null, read_aloud or summarize_aloud: only if the task could be finished by listening instead of looking),
reason (<=15 words: why this situation and interruptibility)

Metrics and previous check:
"""

SITUATIONS = ("deep_work", "meeting", "reading", "casual", "entertainment", "idle")
CONTENT_TYPES = ("coding", "reading", "writing", "video", "design", "chat", "meeting", "spreadsheet", "browsing", "gaming", "other")
# answers that describe the screenshot or the model itself rather than what the user is doing
NONSENSE = ("unknown", "n/a", "none", "screenshot", "image", "cannot", "can't", "unable", "blank", "black screen", "as an ai")

KEYS = ("activity", "content_type", "situation", "focus", "interruptibility", "text_size", "background",
        "long_reading", "voice_task", "reason")


def _post(path, body, timeout):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def _get(path, timeout=2):
    with urllib.request.urlopen(OLLAMA + path, timeout=timeout) as r:
        return json.load(r)


def ollama_exe():
    return shutil.which("ollama", path=os.pathsep.join(OLLAMA_DIRS))


def has_model(names, model):
    """Ollama lists `gemma4` as `gemma4:latest`."""
    return model in names or (":" not in model and f"{model}:latest" in names)


def _parse(raw):
    """The JSON object in a reply; servers without a JSON mode may wrap it in prose or a code fence."""
    m = re.search(r"\{.*\}", raw or "", re.S)
    if not m:
        raise ValueError("the vision model's reply had no JSON")
    return json.loads(m.group(0))


def _normalize(d):
    d = {k: d.get(k) for k in KEYS}
    try:
        d["interruptibility"] = max(0.0, min(1.0, float(d["interruptibility"])))
    except (TypeError, ValueError):
        d["interruptibility"] = None
    if d["focus"] not in ("deep", "light", "none"):
        d["focus"] = None
    if d["situation"] not in SITUATIONS:
        d["situation"] = None
    if d["content_type"] not in CONTENT_TYPES:
        d["content_type"] = None
    return d


def plausible(d):
    """Is this a real description of what the user is doing? A small model that couldn't read the screen tends to
    answer with an empty or generic activity ("a screenshot", "unknown"); those never reach the agent."""
    a = d.get("activity")
    if not isinstance(a, str) or not 4 <= len(a.strip()) <= 140 or d.get("situation") is None:
        return False
    low = a.lower()
    return not any(w in low for w in NONSENSE)


class ScreenWatch:
    def __init__(self, settings_fn, present_fn, metrics_fn=lambda: {}, on_decision=None):
        self.settings = settings_fn
        self.present = present_fn          # () -> bool: only look while the user is at the screen
        self.metrics = metrics_fn          # () -> dict: short metric summary for the prompt
        self.on_decision = on_decision     # (decision) -> None
        self.latest = None
        self.history = collections.deque(maxlen=20)
        self.ok = False
        self.error = None
        self.busy = False
        self.server = None                 # an `ollama serve` we started ourselves
        self.wake = asyncio.Event()

    def fresh(self, max_age=90):
        """The latest decision if it's recent enough to act on."""
        if self.latest and time.time() - self.latest["ts"] <= max_age:
            return self.latest
        return None

    def recent(self, n=4, max_age=180):
        now = time.time()
        return [d for d in list(self.history)[-n:] if now - d["ts"] <= max_age]

    def state(self):
        s = self.settings()
        d = self.latest or {}
        openai = s["privacy.vision_backend"] == "openai"
        return {"enabled": s["privacy.local_vision"], "ok": self.ok, "model": s["privacy.local_model"], "error": self.error,
                "backend": s["privacy.vision_backend"],
                "on_device": not openai or OA.on_this_mac(s["privacy.vision_base_url"]),
                "host": urlparse(s["privacy.vision_base_url"]).hostname if openai else "127.0.0.1",
                "activity": d.get("activity"), "situation": d.get("situation"), "focus": d.get("focus"),
                "interruptibility": d.get("interruptibility"), "reason": d.get("reason"),
                "age_s": round(time.time() - d["ts"]) if d else None}

    def usable(self):
        """The latest description if screen awareness is on, its last check worked and it's recent; else None."""
        s = self.settings()
        if not s["privacy.local_vision"] or not self.ok:
            return None
        return self.fresh(max(120, 3 * s["privacy.screen_interval_s"]))

    def context(self):
        """What the cloud agent gets: text only, and nothing at all unless there's a usable description, so the
        agent never reasons over an empty, stale or made-up one."""
        d = self.usable()
        if not d:
            return None
        now = time.time()
        return {"age_s": round(now - d["ts"]), **{k: d.get(k) for k in KEYS},
                "recent": [{"activity": h["activity"], "situation": h["situation"]} for h in list(self.history)[:-1][-5:]
                           if now - h["ts"] <= 600],
                "privacy": "described on-device by a local model; screen pixels were not sent to you"}

    async def ensure_server(self):
        if self.settings()["privacy.vision_backend"] == "openai":
            return True  # someone else's server: a failed request says what's wrong
        try:
            await asyncio.to_thread(_get, "/api/version")
            return True
        except (urllib.error.URLError, OSError, ValueError):
            pass
        exe = ollama_exe()
        if not exe:
            self.error = "Ollama isn't installed (https://ollama.com), so the screen isn't analyzed"
            return False
        if self.server is None or self.server.poll() is not None:
            self.server = subprocess.Popen([exe, "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(20):
            await asyncio.sleep(0.5)
            try:
                await asyncio.to_thread(_get, "/api/version")
                return True
            except (urllib.error.URLError, OSError, ValueError):
                continue
        self.error = "couldn't start Ollama"
        return False

    async def ollama_models(self):
        if not await self.ensure_server():
            raise RuntimeError(self.error)
        return sorted(m["name"] for m in (await asyncio.to_thread(_get, "/api/tags")).get("models") or [])

    async def ollama_status(self):
        """For the setup checklist: is Ollama installed and running, and is the vision model downloaded?"""
        model = self.settings()["privacy.local_model"]
        out = {"installed": bool(ollama_exe()), "running": False, "model": model, "has_model": False}
        try:
            names = await self.ollama_models()
        except Exception as e:  # noqa: BLE001 - not installed, or it wouldn't start
            return {**out, "error": str(e)[:200]}
        return {**out, "installed": True, "running": True, "has_model": has_model(names, model)}

    async def pull(self, model, progress):
        """Download a model with Ollama's /api/pull; progress(dict) gets each status line as it streams."""
        if not await self.ensure_server():
            raise RuntimeError(self.error)
        loop = asyncio.get_running_loop()

        def go():
            req = urllib.request.Request(OLLAMA + "/api/pull", data=json.dumps({"model": model, "name": model}).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=600) as r:
                for line in r:
                    m = json.loads(line)
                    if m.get("error"):
                        raise RuntimeError(m["error"])
                    loop.call_soon_threadsafe(progress, m)
        await asyncio.to_thread(go)
        self.error = None
        self.wake.set()  # look at the screen now that there's a model

    async def ask(self, prompt, images=(), json_mode=True, timeout=180):
        """One chat turn with the vision model. Returns the reply text."""
        s = self.settings()
        if s["privacy.vision_backend"] == "openai":  # no portable JSON mode: describe_now pulls the JSON out of the reply
            return await OA.ask(s["privacy.vision_base_url"], s["privacy.local_model"], prompt, images,
                                os.environ.get(OA.VISION_KEY_ENV), timeout)
        body = {"model": s["privacy.local_model"], "stream": False, "think": False, "keep_alive": "15m",
                "options": {"temperature": 0.1, "num_ctx": 8192},
                "messages": [{"role": "user", "content": prompt, "images": list(images)}]}
        if json_mode:
            body["format"] = "json"
        r = await asyncio.to_thread(_post, "/api/chat", body, timeout)
        return r["message"]["content"]

    async def describe_now(self):
        if self.busy:
            return self.latest
        self.busy = True
        shot = None
        try:
            if not await self.ensure_server():
                self.ok = False
                return None
            shot = await asyncio.to_thread(S.screenshot_jpeg, 1280)
            if not shot:
                self.ok, self.error = False, "no Screen Recording permission"
                return None
            prev = {k: self.latest.get(k) for k in ("activity", "situation", "focus", "interruptibility")} if self.latest else None
            info = json.dumps({"metrics": self.metrics(), "previous_check": prev}, default=str)
            raw = await self.ask(PROMPT + info, [base64.b64encode(shot).decode()])
            d = _normalize(_parse(raw))
            if not plausible(d):
                self.ok, self.error = False, "the vision model's answer didn't describe the screen, so it was ignored"
                return None
            d["ts"] = time.time()
            self.latest = d
            self.history.append(d)
            self.ok, self.error = True, None
            if self.on_decision:
                self.on_decision(d)
            return d
        except urllib.error.HTTPError as e:
            self.ok = False
            self.error = f"local model error ({e.code}); is `{self.settings()['privacy.local_model']}` pulled in Ollama?"
        except Exception as e:  # noqa: BLE001 - screen understanding is optional; never break the app
            self.ok, self.error = False, f"{type(e).__name__}: {e}"[:200]
        finally:
            S.wipe(shot)  # the screenshot is gone for good once the check is done
            self.busy = False
        return None

    async def loop(self):
        while True:
            s = self.settings()
            try:
                await asyncio.wait_for(self.wake.wait(), s["privacy.screen_interval_s"])
            except asyncio.TimeoutError:
                pass
            self.wake.clear()
            s = self.settings()
            if s["privacy.local_vision"] and not s["tracking.paused"] and self.present():
                await self.describe_now()

    def stop(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()

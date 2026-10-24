"""The conductor: an on-device vision model that looks at the screen every 30 s and tells eyeOS what's going on.

Each check combines one screenshot with the eye/posture metrics and the previous check's text, and returns what the
user is doing, the situation (deep work, meeting, casual...), how deep the focus is and how interruptible they are.
eyeOS uses that to enter/leave Zen and to decide whether a nudge should go out now or wait.

Privacy: the screenshot is captured straight into memory, never written to disk, sent only to the local model
(Ollama on 127.0.0.1) and wiped as soon as the check is done. The cloud agent only ever gets the text below,
which the prompt keeps free of names, numbers and quoted private text. Continuity between checks comes from the
previous check's text, not from keeping old images.
"""
import asyncio
import base64
import collections
import json
import shutil
import subprocess
import time
import urllib.error
import urllib.request

from .tools import system as S

OLLAMA = "http://127.0.0.1:11434"

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

KEYS = ("activity", "content_type", "situation", "focus", "interruptibility", "text_size", "background",
        "long_reading", "voice_task", "reason")


def _post(path, body, timeout):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def _get(path, timeout=2):
    with urllib.request.urlopen(OLLAMA + path, timeout=timeout) as r:
        return json.load(r)


def _normalize(d):
    d = {k: d.get(k) for k in KEYS}
    try:
        d["interruptibility"] = max(0.0, min(1.0, float(d["interruptibility"])))
    except (TypeError, ValueError):
        d["interruptibility"] = None
    if d["focus"] not in ("deep", "light", "none"):
        d["focus"] = None
    return d


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
        return {"enabled": s["privacy.local_vision"], "ok": self.ok, "model": s["privacy.local_model"], "error": self.error,
                "activity": d.get("activity"), "situation": d.get("situation"), "focus": d.get("focus"),
                "interruptibility": d.get("interruptibility"), "reason": d.get("reason"),
                "age_s": round(time.time() - d["ts"]) if d else None}

    def context(self):
        """What the cloud agent gets: text only."""
        if not self.latest:
            return {"available": False, "note": self.error or "no on-device screen description yet"}
        return {"available": True, "age_s": round(time.time() - self.latest["ts"]),
                **{k: self.latest.get(k) for k in KEYS},
                "recent": [{"activity": h["activity"], "situation": h["situation"]} for h in list(self.history)[:-1][-5:]],
                "privacy": "described on-device by a local model; screen pixels were not sent to you"}

    async def ensure_server(self):
        try:
            await asyncio.to_thread(_get, "/api/version")
            return True
        except (urllib.error.URLError, OSError, ValueError):
            pass
        exe = shutil.which("ollama", path="/usr/local/bin:/opt/homebrew/bin:/Applications/Ollama.app/Contents/Resources")
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

    async def ask(self, prompt, images=(), json_mode=True, timeout=180):
        """One local chat turn. Returns the reply text."""
        s = self.settings()
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
            d = _normalize(json.loads(raw))
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

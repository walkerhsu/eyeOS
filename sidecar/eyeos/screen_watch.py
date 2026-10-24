"""On-device screen understanding: a local vision model (Ollama) describes what the user is doing every minute.

Screen pixels never leave the Mac. The cloud agent (Claude / Codex) only ever receives the short text description
below, which the prompt asks to keep free of names, numbers and quoted private text.
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

PROMPT = """You see a screenshot of the user's Mac screen. Describe ONLY what the user is doing, in a privacy-preserving way:
no names, emails, numbers, URLs or quoted private text. Reply as JSON with keys:
activity (<=12 words, e.g. "editing Python code in VS Code"),
content_type (one of: coding, reading, writing, video, design, chat, meeting, spreadsheet, browsing, gaming, other),
text_size (small, normal, large),
background (light, dark, mixed),
long_reading (true if the user is reading a long article or document),
voice_task (null, or one of: read_aloud, summarize_aloud - only if the current task could be finished by listening instead of looking),
voice_reason (<=12 words or null)"""

KEYS = ("activity", "content_type", "text_size", "background", "long_reading", "voice_task", "voice_reason")


def _post(path, body, timeout):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def _get(path, timeout=2):
    with urllib.request.urlopen(OLLAMA + path, timeout=timeout) as r:
        return json.load(r)


class ScreenWatch:
    def __init__(self, settings_fn, present_fn):
        self.settings = settings_fn
        self.present = present_fn          # () -> bool: only look while the user is at the screen
        self.latest = None                 # last description + ts
        self.history = collections.deque(maxlen=10)
        self.ok = False
        self.error = None
        self.busy = False
        self.server = None                 # an `ollama serve` we started ourselves
        self.wake = asyncio.Event()

    def state(self):
        s = self.settings()
        age = round(time.time() - self.latest["ts"]) if self.latest else None
        return {"enabled": s["privacy.local_vision"], "ok": self.ok, "model": s["privacy.local_model"], "error": self.error,
                "activity": (self.latest or {}).get("activity"), "age_s": age}

    def context(self):
        """What the cloud agent gets: text only."""
        if not self.latest:
            return {"available": False, "note": self.error or "no on-device screen description yet"}
        return {"available": True, "age_s": round(time.time() - self.latest["ts"]),
                **{k: self.latest.get(k) for k in KEYS},
                "recent_activities": [h["activity"] for h in list(self.history)[:-1][-5:]],
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
        try:
            if not await self.ensure_server():
                self.ok = False
                return None
            jpg = await asyncio.to_thread(S.screenshot_jpeg, 1280)
            if not jpg:
                self.ok, self.error = False, "no Screen Recording permission"
                return None
            raw = await self.ask(PROMPT, [base64.b64encode(jpg).decode()])
            d = json.loads(raw)
            d = {k: d.get(k) for k in KEYS}
            d["ts"] = time.time()
            self.latest = d
            self.history.append(d)
            self.ok, self.error = True, None
            return d
        except urllib.error.HTTPError as e:
            self.ok = False
            self.error = f"local model error ({e.code}); is `{self.settings()['privacy.local_model']}` pulled in Ollama?"
        except Exception as e:  # noqa: BLE001 - screen understanding is optional; never break the app
            self.ok, self.error = False, f"{type(e).__name__}: {e}"[:200]
        finally:
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

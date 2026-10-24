"""Cartesia TTS -> cached WAV -> sequential afplay (SPEC §9.8)."""
import asyncio
import hashlib
import os
import re
import signal
import time
from pathlib import Path

from .tools.system import osa, run

CACHE = Path.home() / "Library/Caches/eyeOS/tts"
MODEL = "sonic-3"


def chunks(text, limit=600):
    out, cur = [], ""
    for para in re.split(r"\n\s*\n|(?<=[.!?])\s+", text):
        para = para.strip()
        if not para:
            continue
        while len(para) > limit:  # hard-split very long sentences on spaces
            cut = para.rfind(" ", 0, limit)
            cut = cut if cut > 0 else limit
            out.append(para[:cut])
            para = para[cut:].strip()
        if len(cur) + len(para) + 1 > limit:
            out.append(cur)
            cur = para
        else:
            cur = f"{cur} {para}".strip()
    if cur:
        out.append(cur)
    return out


def clean_page(text, limit=8000):
    lines = [re.sub(r"\s+", " ", l).strip() for l in text.splitlines()]
    return "\n\n".join(l for l in lines if len(l) >= 30)[:limit]


def page_text(bundle_id):
    if bundle_id == "com.apple.Safari":
        ok, out = osa('tell application "Safari" to do JavaScript "document.body.innerText" in current tab of front window', 15)
    elif bundle_id == "com.google.Chrome":
        ok, out = osa('tell application "Google Chrome" to execute front window\'s active tab javascript "document.body.innerText"', 15)
    else:
        return None, "browser_tab only works in Safari or Chrome"
    return (clean_page(out), None) if ok else (None, out)


def selection_text():
    # shortcut: saves/restores plain-text clipboard only; rich clipboard content is lost.
    _, saved = run(["pbpaste"], 3)
    run(["pbcopy"], 3, input="")
    osa('tell application "System Events" to keystroke "c" using command down')
    time.sleep(0.3)
    _, text = run(["pbpaste"], 3)
    run(["pbcopy"], 3, input=saved)
    return text.strip()


class Speaker:
    def __init__(self, settings_fn):
        self.settings_fn = settings_fn
        self.proc = None
        self.task = None
        self.voice = None
        self._client = None

    def client(self):
        if self._client is None:
            from cartesia import Cartesia
            self._client = Cartesia(api_key=os.environ.get("CARTESIA_API_KEY", ""))
        return self._client

    def _voice(self):
        v = self.settings_fn().get("audio.voice_id")
        if v:
            return v
        if self.voice is None:
            self.voice = next(iter(self.client().voices.list(limit=1))).id
        return self.voice

    def synth(self, text):
        """Blocking: returns a cached audio path. Without a Cartesia key it uses macOS `say`, fully on-device."""
        s = self.settings_fn()
        if not os.environ.get("CARTESIA_API_KEY"):
            CACHE.mkdir(parents=True, exist_ok=True)
            path = CACHE / (hashlib.sha1(f"say|{s['audio.speed']}|{text}".encode()).hexdigest() + ".aiff")
            if not path.exists():
                ok, err = run(["say", "-r", str(int(180 * s["audio.speed"])), "-o", str(path), text], timeout=60)
                if not ok:
                    raise RuntimeError(f"say failed: {err}")
            return path
        voice = self._voice()
        CACHE.mkdir(parents=True, exist_ok=True)
        path = CACHE / (hashlib.sha1(f"{voice}|{s['audio.speed']}|{text}".encode()).hexdigest() + ".wav")
        if not path.exists():
            data = b"".join(self.client().tts.bytes(
                model_id=MODEL, transcript=text, voice={"id": voice},
                output_format={"container": "wav", "encoding": "pcm_s16le", "sample_rate": 24000},
                generation_config={"speed": s["audio.speed"]}))
            path.write_bytes(data)
        return path

    def busy(self):
        return self.task is not None and not self.task.done()

    async def speak(self, texts, on_done=None):
        """Play texts sequentially, synthesizing the next chunk while the current one plays."""
        await self.stop()
        self.task = asyncio.create_task(self._play(texts, on_done))

    async def _play(self, texts, on_done):
        try:
            nxt = asyncio.create_task(asyncio.to_thread(self.synth, texts[0])) if texts else None
            for i in range(len(texts)):
                path = await nxt
                nxt = asyncio.create_task(asyncio.to_thread(self.synth, texts[i + 1])) if i + 1 < len(texts) else None
                self.proc = await asyncio.create_subprocess_exec("afplay", str(path))
                await self.proc.wait()
                self.proc = None
        finally:
            self.proc = None
            if on_done:
                await on_done()

    def control(self, action):
        if action == "stop":
            return asyncio.ensure_future(self.stop())
        if self.proc and self.proc.returncode is None:
            self.proc.send_signal(signal.SIGSTOP if action == "pause" else signal.SIGCONT)

    async def stop(self):
        if self.task and not self.task.done():
            self.task.cancel()
        if self.proc and self.proc.returncode is None:
            self.proc.send_signal(signal.SIGCONT)
            self.proc.kill()
        self.proc = None

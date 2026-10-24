"""Generates the bundled ambient cues (chime, rain, bowl) as 44.1 kHz mono WAVs."""
import sys, wave
from pathlib import Path
import numpy as np

SR = 44100
out = Path(sys.argv[1])


def save(name, x):
    x = (x / np.abs(x).max() * 0.6 * 32767).astype(np.int16)
    with wave.open(str(out / f"{name}.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(x.tobytes())


t = np.arange(int(SR * 2.5)) / SR
save("chime", sum(np.sin(2 * np.pi * f * t) * np.exp(-t * d) for f, d in ((1318.5, 2.2), (1975.5, 3.0), (2637, 4.0))))
t = np.arange(int(SR * 3.5)) / SR
save("bowl", sum(a * np.sin(2 * np.pi * f * t) * np.exp(-t * 0.9) for f, a in ((220, 1), (221.5, 0.8), (587, 0.35), (1040, 0.15))))
rng = np.random.default_rng(1)
n = rng.standard_normal(int(SR * 3))
rain = np.convolve(n, np.ones(8) / 8, "same") * (0.6 + 0.4 * np.sin(np.linspace(0, 3 * np.pi, n.size)) ** 2)
env = np.minimum(1, np.minimum(np.arange(n.size), n.size - np.arange(n.size)) / (SR * 0.5))
save("rain", rain * env)

"""Shows how deep your blinks really go, to pick the full-vs-incomplete thresholds from data.

Replays a `--record` file through the metrics engine (as fast as possible) with your saved calibration and
reports every dip: how low eye openness went (min_o, the EAR rule) and how high MediaPipe's eyeBlink
blendshape peaked. Results are split into the recording protocol's segments.

Record (quit the eyeOS app first so the camera is free), then report:
  uv run python -m eyeos --record /tmp/blinks.jsonl.gz      # Ctrl-C after ~2 min
  uv run python scripts/blink_report.py /tmp/blinks.jsonl.gz

Protocol: 0-60 s blink naturally while reading · 60-80 s 10 deliberate full blinks ·
80-100 s 10 half blinks · 100-120 s read the bottom of the screen. Change the cut points with --segments.
"""
import argparse
import gzip
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from anywhere without installing eyeos
from eyeos import metrics as M  # noqa: E402
from eyeos.db import DB  # noqa: E402

NAMES = ["natural", "full (deliberate)", "half", "looking down"]
O_CUTS = [0.20, 0.30, 0.35, 0.40, 0.50]
BLEND_CUTS = [0.30, 0.40, 0.50, 0.60, 0.70]


def load(path, cal):
    """Replays the recording; returns (dips, t0, t_end). A dip is any run of non-OPEN frames."""
    eng = M.Engine(cal=cal)
    samples = []
    eng.recorder = samples.append
    closure = {}
    t0 = t_end = None
    with gzip.open(path, "rt") as fh:
        for line in fh:
            f = json.loads(line)
            t0 = f["ts"] if t0 is None else t0
            t_end = f["ts"]
            b = f.get("blend") or {}
            if "eyeBlinkLeft" in b:
                closure[f["ts"]] = (b["eyeBlinkLeft"] + b.get("eyeBlinkRight", b["eyeBlinkLeft"])) / 2
            eng.update(f)
    dips, cur = [], None
    for s in samples:
        if not s.get("present") or s.get("o") is None:
            continue
        if s["state"] != "OPEN":
            cur = cur or {"start": s["ts"], "frames": 0, "min_o": 9.0, "peak": None}
            cur["frames"] += 1
            cur["min_o"] = min(cur["min_o"], s["o"])
            c = closure.get(s["ts"])
            if c is not None:
                cur["peak"] = c if cur["peak"] is None else max(cur["peak"], c)
            cur["end"] = s["ts"]
        elif cur:
            dips.append(cur)
            cur = None
    return dips, t0, t_end


def hist(values, edges):
    rows = []
    for lo, hi in zip(edges, edges[1:]):
        n = sum(1 for v in values if lo <= v < hi)
        rows.append(f"    {lo:4.2f}-{hi:4.2f} {'#' * n} {n or ''}")
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("recording")
    ap.add_argument("--segments", default="60,80,100", help="segment cut points in seconds (default 60,80,100)")
    ap.add_argument("--ear-open", type=float, help="override the calibrated open-eye EAR")
    a = ap.parse_args()

    cal = DB().baseline()
    if a.ear_open:
        cal["ear_open"] = a.ear_open
    dips, t0, t_end = load(a.recording, cal)
    print(f"recording {t_end - t0:.0f} s · ear_open {cal.get('ear_open')} · {len(dips)} dips "
          f"(2+ frames: {sum(d['frames'] >= 2 for d in dips)})")
    if not any(d["peak"] is not None for d in dips):
        print("note: no eyeBlink blendshapes in this recording")

    cuts = [0] + [float(x) for x in a.segments.split(",")] + [1e9]
    for i, (lo, hi) in enumerate(zip(cuts, cuts[1:])):
        seg = [d for d in dips if lo <= d["start"] - t0 < hi and d["frames"] >= 2]
        span = min(hi, t_end - t0) - lo
        if span <= 0:
            continue
        name = NAMES[i] if i < len(NAMES) else f"segment {i + 1}"
        print(f"\n== {name} ({lo:.0f}-{lo + span:.0f} s): {len(seg)} dips, {len(seg) / span * 60:.1f}/min")
        if not seg:
            continue
        print("  min_o (lower = more closed):")
        print(hist([d["min_o"] for d in seg], [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.75]))
        peaks = [d["peak"] for d in seg if d["peak"] is not None]
        if peaks:
            print("  eyeBlink peak (higher = more closed):")
            print(hist(peaks, [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.01]))
        print("  counted as full blinks if min_o <= …:  " +
              "  ".join(f"{c:.2f}→{sum(d['min_o'] <= c for d in seg)}" for c in O_CUTS))
        if peaks:
            print("  … or if eyeBlink peak >= …:          " +
                  "  ".join(f"{c:.2f}→{sum(d['min_o'] <= O_CUTS[0] or (d['peak'] or 0) >= c for d in seg)}"
                            for c in BLEND_CUTS))


if __name__ == "__main__":
    main()

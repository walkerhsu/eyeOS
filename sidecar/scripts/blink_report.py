"""Shows how deep your blinks really go, to pick the full-vs-incomplete thresholds from data.

Replays `--record` files through the metrics engine (as fast as possible) with your saved calibration and
reports every dip: how low eye openness went (min_o, the EAR rule) and how high MediaPipe's eyeBlink
blendshape peaked.

Record one short file per phase (quit the eyeOS app first so the camera is free; Ctrl-C ends each one), so
no timing is needed: each file is labeled by its name.
  uv run python -m eyeos --record /tmp/natural.jsonl.gz   # ~60 s reading normally
  uv run python -m eyeos --record /tmp/full.jsonl.gz      # 10 deliberate full blinks
  uv run python -m eyeos --record /tmp/half.jsonl.gz      # 10 half blinks
  uv run python -m eyeos --record /tmp/down.jsonl.gz      # ~20 s reading the bottom of the screen
  uv run python scripts/blink_report.py /tmp/natural.jsonl.gz /tmp/full.jsonl.gz /tmp/half.jsonl.gz /tmp/down.jsonl.gz

A single file is split by time instead (--segments, default 60,80,100 s for the same four phases).
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


def report(name, seg, span):
    print(f"\n== {name} ({span:.0f} s): {len(seg)} dips, {len(seg) / span * 60:.1f}/min")
    if not seg:
        return
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("recordings", nargs="+", help="one file per phase, or a single file split with --segments")
    ap.add_argument("--segments", default="60,80,100", help="single file only: cut points in seconds (default 60,80,100)")
    ap.add_argument("--ear-open", type=float, help="override the calibrated open-eye EAR")
    a = ap.parse_args()

    cal = DB().baseline()
    if a.ear_open:
        cal["ear_open"] = a.ear_open
    print(f"ear_open {cal.get('ear_open')} (from your calibration unless --ear-open)")
    for path in a.recordings:
        dips, t0, t_end = load(path, cal)
        if t0 is None:
            print(f"\n== {path}: empty recording")
            continue
        if not any(d["peak"] is not None for d in dips):
            print(f"note: no eyeBlink blendshapes in {path}")
        if len(a.recordings) > 1:
            name = Path(path).name.split(".")[0]
            report(name, [d for d in dips if d["frames"] >= 2], max(1.0, t_end - t0))
            continue
        cuts = [0] + [float(x) for x in a.segments.split(",")] + [1e9]
        for i, (lo, hi) in enumerate(zip(cuts, cuts[1:])):
            span = min(hi, t_end - t0) - lo
            if span > 0:
                report(NAMES[i] if i < len(NAMES) else f"segment {i + 1}",
                       [d for d in dips if lo <= d["start"] - t0 < hi and d["frames"] >= 2], span)


if __name__ == "__main__":
    main()

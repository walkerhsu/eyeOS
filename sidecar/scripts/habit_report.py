"""Checks the habit coach's hand and squint detection against real recordings, to tune it from data.

Replays `--record` files through the metrics engine (as fast as possible) with your saved calibration and reports,
per file: touch / rub / lash-pull events, how soon after the fingers reached an eye the cue fired, how often hands
were tracked, how close hands came to the eyes, and squinting.

Record one short file per phase (quit the eyeOS app first so the camera is free; Ctrl-C ends each one). The file
name says what you did, so the report knows what to expect:
  uv run python -m eyeos --record /tmp/rub.jsonl.gz       # rub an eye, 5 times
  uv run python -m eyeos --record /tmp/hair.jsonl.gz      # play with your hair, hand on your head, ~30 s
  uv run python -m eyeos --record /tmp/chin.jsonl.gz      # chin or cheek in hand, push up glasses, ~30 s
  uv run python -m eyeos --record /tmp/lash.jsonl.gz      # pull or tug at your lashes, 5 times
  uv run python -m eyeos --record /tmp/squint.jsonl.gz    # squint at small text, ~20 s
  uv run python -m eyeos --record /tmp/down.jsonl.gz      # read the bottom of the screen, ~20 s
  uv run python scripts/habit_report.py /tmp/*.jsonl.gz

Any ✗ points at a constant: TOUCH at the top of eyeos/metrics.py (or _squinting there), ZOOM in eyeos/habits.py.
"""
import argparse
import gzip
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from anywhere without installing eyeos
from eyeos import metrics as M  # noqa: E402
from eyeos.db import DB  # noqa: E402

NOTHING = lambda r: r["touch"] == r["rub"] == r["lash_pull"] == 0
CALM = lambda r: r["squint_frames"] / max(1, r["frames"]) < 0.1
# file-name keyword -> (what should happen, check)
EXPECT = {
    "rub": ("touches cued, rubs counted", lambda r: r["touch"] > 0 and r["rub"] > 0),
    "lash": ("lash pulls counted, not rubs", lambda r: r["lash_pull"] > 0 and r["rub"] == 0),
    "hair": ("nothing", NOTHING), "head": ("nothing", NOTHING), "chin": ("nothing", NOTHING),
    "glasses": ("nothing", NOTHING),
    "squint": ("squinting within ~10 s", lambda r: r["squint_first"] is not None and r["squint_first"] <= 10),
    "down": ("no squinting (looking down isn't squinting)", CALM),
    "natural": ("no squinting", CALM),
}


def replay(path, cal):
    eng = M.Engine(cal=cal)
    r = {"touch": 0, "rub": 0, "lash_pull": 0, "lat": [], "near": [], "squint_first": None, "squint_max": 0.0,
         "squint_frames": 0, "frames": 0, "hand_frames": 0}
    contact, t0, t_end = None, None, None
    with gzip.open(path, "rt") as fh:
        for line in fh:
            f = json.loads(line)
            t0 = f["ts"] if t0 is None else t0
            t_end = f["ts"]
            r["frames"] += 1
            evs = eng.update(f)
            if f.get("hands") is not None:
                r["hand_frames"] += 1
                d = eng.hand_eye_r
                if d is not None:
                    r["near"].append(d)
                if d is not None and d < M.TOUCH["r"]:
                    contact = contact or f["ts"]  # fingers reached an eye
                elif d is None or d > 0.5:
                    contact = None
            for e in evs:
                if e["kind"] in ("touch", "rub", "lash_pull"):
                    r[e["kind"]] += 1
                if e["kind"] == "touch" and contact:
                    r["lat"].append(e["ts"] - contact)
            s = eng.snapshot(f["ts"])
            if s["squinting"]:
                r["squint_frames"] += 1
                if r["squint_first"] is None:
                    r["squint_first"] = f["ts"] - t0
            r["squint_max"] = max(r["squint_max"], s["squint_s"] or 0)
    r["seconds"] = (t_end - t0) if t0 is not None else 0
    return r


def report(path, r):
    secs = r["seconds"] or 1e-9
    print(f"\n{Path(path).name}  ({r['seconds']:.0f} s, {r['frames'] / secs:.0f} fps, hands tracked {r['hand_frames'] / secs:.0f}/s)")
    print(f"  touches cued {r['touch']} · rubs {r['rub']} · lash pulls {r['lash_pull']}")
    if r["lat"]:
        print(f"  cue after fingers reached an eye: median {statistics.median(r['lat']):.2f} s, max {max(r['lat']):.2f} s")
    if r["near"]:
        n = sorted(r["near"])
        print(f"  nearest fingertip to an eye: min {n[0]:.2f} IOD, median {statistics.median(n):.2f} IOD "
              f"(touching < {M.TOUCH['r']}, and only counts with the eyes closing)")
    print(f"  squinting {r['squint_frames'] / max(1, r['frames']):.0%} of frames, longest {r['squint_max']:.0f} s"
          + (f", first after {r['squint_first']:.1f} s" if r["squint_first"] is not None else ""))
    for key, (want, ok) in EXPECT.items():
        if key in Path(path).name.lower():
            print(f"  {'✓' if ok(r) else '✗'} expected: {want}")
            break


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--db", help="database with your calibration (default: the app's)")
    a = ap.parse_args()
    cal = (DB(a.db) if a.db else DB()).baseline()
    if not cal.get("calibrated"):
        print("note: no saved calibration, using defaults (distances and openness will be rough)")
    for path in a.files:
        report(path, replay(path, cal))


if __name__ == "__main__":
    main()

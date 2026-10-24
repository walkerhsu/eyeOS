import gzip
import json
from pathlib import Path

import pytest

from eyeos import metrics as M

ADV = M.DEFAULT_ADV


def run_dips(seq, fps=30):
    d = M.DipDetector(ADV)
    out = []
    for i, o in enumerate(seq):
        ev = d.update(i / fps, o)
        if ev:
            out.append(ev)
    return out


def test_ear_hand_built():
    # p1..p6: corners 10 apart horizontally, lids 2 apart vertically -> EAR 0.2
    pts = {0: (0, 0), 1: (3, 1), 2: (7, 1), 3: (10, 0), 4: (7, -1), 5: (3, -1)}
    assert M.ear(pts, (0, 1, 2, 3, 4, 5)) == pytest.approx(0.2)


def test_distance_formula():
    assert M.distance_cm(10, w_px_cal=20, d_cal_cm=60) == pytest.approx(120)
    assert M.distance_cm(20, w_px_cal=20, d_cal_cm=60) == pytest.approx(60)
    assert M.distance_cm(11.7, None, frame_w=640) == pytest.approx(64.0)


def test_gaze_ratio_center():
    face = [[0, 0, 0]] * 478
    face = [list(p) for p in face]
    face[33], face[133], face[468] = [0.40, 0.5, 0], [0.46, 0.5, 0], [0.43, 0.5, 0]
    face[263], face[362], face[473] = [0.60, 0.5, 0], [0.54, 0.5, 0], [0.57, 0.5, 0]
    face[159], face[145], face[386], face[374] = [0, 0.48, 0], [0, 0.52, 0], [0, 0.48, 0], [0, 0.52, 0]
    gx, gy = M.gaze(face)
    assert gx == pytest.approx(0.5) and gy == pytest.approx(0.5)


def test_two_frame_dip_is_blink():
    ev = run_dips([1, 1, 0.1, 0.1, 1, 1])
    assert [e["kind"] for e in ev] == ["blink"]


def test_one_frame_dip_is_noise():
    assert run_dips([1, 1, 0.1, 1, 1]) == []


def test_shallow_dip_is_incomplete():
    ev = run_dips([1, 0.6, 0.4, 0.5, 1])
    assert [e["kind"] for e in ev] == ["incomplete"]


def test_very_shallow_dip_is_noise():
    assert run_dips([1, 0.7, 0.65, 0.7, 1]) == []


def test_long_blink_and_closed():
    ev = run_dips([1] + [0.1] * 21 + [1])  # 0.7 s
    assert ev[0]["kind"] == "blink" and ev[0]["long"]
    ev = run_dips([1] + [0.05] * 150 + [1])  # 5 s
    assert ev[0]["kind"] == "eyes_closed" and ev[0]["duration"] == pytest.approx(5.0, abs=0.1)


def test_verdict():
    assert M.verdict("blink_rate", 6, 9) == "improved"
    assert M.verdict("blink_rate", 9, 6) == "worse"
    assert M.verdict("blink_rate", 8, 9) == "neutral"
    assert M.verdict("squint_delta", 0.30, 0.20) == "improved"
    assert M.verdict("squint_delta", 0.20, 0.30) == "worse"
    assert M.verdict("squint_delta", 0.20, 0.21) == "neutral"
    assert M.verdict("blink_rate", 6, 9, face_frac=0.3) == "inconclusive"


def _synth_face(o_ratio=1.0, iris=12.0):
    """A face whose EAR = 0.28 * o_ratio (in 640x480 px) and iris width = `iris` px."""
    face = [[0.5, 0.5, 0.0] for _ in range(478)]
    w, h = 640, 480
    half = 0.28 * o_ratio * 30 / 2  # eye 30 px wide

    def eye(idx, cx, inner_right):
        p1, p2, p3, p4, p5, p6 = idx
        x0, x1 = (cx - 15) / w, (cx + 15) / w
        face[p1], face[p4] = [x0, 0.5, 0], [x1, 0.5, 0]
        for a, b, fx in ((p2, p6, cx - 5), (p3, p5, cx + 5)):
            face[a] = [fx / w, (240 - half) / h, 0]
            face[b] = [fx / w, (240 + half) / h, 0]
    eye(M.R_EAR, 280, True)
    eye(M.L_EAR, 360, False)
    # gaze: iris centered between corners
    face[468] = [280 / w, 0.5, 0]
    face[473] = [360 / w, 0.5, 0]
    face[159], face[145] = [280 / w, (240 - 3) / h, 0], [280 / w, (240 + 3) / h, 0]
    face[386], face[374] = [360 / w, (240 - 3) / h, 0], [360 / w, (240 + 3) / h, 0]
    for c, (a, b) in ((280, (469, 471)), (360, (474, 476))):
        face[a], face[b] = [(c - iris / 2) / w, 0.5, 0], [(c + iris / 2) / w, 0.5, 0]
    return face


def _feed(eng, t0, seconds, o_fn, fps=30, **extra):
    n = int(seconds * fps)
    evs = []
    for i in range(n):
        t = t0 + i / fps
        o = o_fn(t - t0)
        face = None if o is None else _synth_face(o)
        evs += eng.update({"ts": t, "w": 640, "h": 480, "face": face, "blend": {}, "transform": None,
                           "hands": None, "luma": 100.0, **extra})
    return evs, t0 + n / fps


def test_engine_blink_rate_and_stare():
    eng = M.Engine()
    # 60 s with a 0.2 s complete blink every 6 s -> 10 blinks/min, stare ~5.8 s
    evs, t = _feed(eng, 1000.0, 60.5, lambda s: 0.1 if (s % 6) > 5.8 else 1.0)
    s = eng.snapshot()
    assert sum(e["kind"] == "blink" for e in evs) == 10  # dips end at 6,12..60 s
    assert s["blink_rate"] == pytest.approx(10, abs=1)
    assert s["longest_stare_s"] == pytest.approx(5.8, abs=0.3)
    assert s["perclos"] == pytest.approx(0.2 / 6, abs=0.02)
    assert s["distance_cm"] is not None


def test_engine_real_break():
    eng = M.Engine()
    _, t = _feed(eng, 0.0, 5, lambda s: 1.0)
    _, t = _feed(eng, t, 25, lambda s: None)  # absent 25 s
    evs, t = _feed(eng, t, 1, lambda s: 1.0)
    assert [e["kind"] for e in evs] == ["break"]
    assert eng.snapshot()["since_real_break_s"] <= 1


def test_engine_rub():
    eng = M.Engine()
    _, t = _feed(eng, 0.0, 1, lambda s: 1.0)
    rc = M.eye_center(_synth_face(), M.R_EAR)
    hand = [[rc[0], rc[1], 0] for _ in range(21)]
    evs, t = _feed(eng, t, 1.5, lambda s: None, hands=[hand])
    assert sum(e["kind"] == "rub" for e in evs) == 1


FIX = Path(__file__).parent / "fixtures" / "session_a.jsonl.gz"


@pytest.mark.skipif(not FIX.exists(), reason="record tests/fixtures/session_a.jsonl.gz first (SPEC §13)")
def test_fixture_session():
    truth = json.loads(FIX.with_name("session_a.truth.json").read_text())
    eng = M.Engine()
    evs, max_perclos = [], 0
    with gzip.open(FIX, "rt") as fh:
        for line in fh:
            evs += eng.update(json.loads(line))
            max_perclos = max(max_perclos, eng.snapshot()["perclos"] or 0)
    count = lambda k: sum(e["kind"] == k for e in evs)
    assert abs(count("blink") - truth["blinks"]) <= 1
    assert abs(count("incomplete") - truth["incomplete"]) <= 1
    assert abs(max(g for _, g in eng.stares) - truth["longest_stare_s"]) <= 1
    assert sum(e["kind"] == "blink" and e["long"] for e in evs) == 3
    assert any(e["kind"] == "eyes_closed" and 4 <= e["duration"] <= 6 for e in evs)
    assert max_perclos > 0.08
    assert count("rub") == 1
    assert count("yawn") == 2
    assert count("break") == 1

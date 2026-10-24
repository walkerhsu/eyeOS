"""Blink band, talking exclusion, blink-decline trend and posture drift."""
from eyeos import metrics as M
from eyeos.db import DB
from eyeos.triggers import Triggers
from eyeos.zen import blink_base, blink_high, blink_low, eye_score


def engine():
    return M.Engine(cal={"calibrated": True, "blink_rate": 15})


def test_band_is_relative_to_baseline_and_clamped():
    assert blink_base({"blink_rate": 5}) == 10        # a bad (too low) calibration is clamped
    assert blink_base({"blink_rate": None}) == 15
    assert blink_low(15) == 9 and blink_low(25) == 15
    assert blink_high(15) == 25 and blink_high(20) == 32


def test_eye_score_penalizes_both_sides():
    base = {"face_present": True, "calibrated": True}
    cal = {"blink_rate": 15}
    normal = eye_score({**base, "blink_rate": 15}, cal)
    assert eye_score({**base, "blink_rate": 5}, cal) < normal
    assert eye_score({**base, "blink_rate": 40}, cal) < normal
    assert eye_score({**base, "blink_rate": 15, "blink_trend": {"declining": True}}, cal) == normal - 10


def fire(tid, snap, tmp_path):
    s = DB(tmp_path / "t.db").settings()
    t = Triggers()
    t.evaluate(snap, [], s, 0)
    return [x["id"] for x in t.evaluate(snap, [], s, 10_000)]


def test_frequent_and_low_blink_triggers(tmp_path):
    assert "frequent_blinks" in fire("frequent_blinks", {"blink_rate": 30, "baseline_blink_rate": 15}, tmp_path)
    assert "frequent_blinks" not in fire("frequent_blinks", {"blink_rate": 22, "baseline_blink_rate": 15}, tmp_path)
    assert "low_blink_rate" in fire("low_blink_rate", {"blink_rate": 7, "baseline_blink_rate": 15}, tmp_path)
    # talking / on a call -> blink_rate is None -> neither fires
    ids = fire("x", {"blink_rate": None, "baseline_blink_rate": 15}, tmp_path)
    assert "low_blink_rate" not in ids and "frequent_blinks" not in ids


def test_blink_decline_detects_steady_slide():
    e = engine()
    rates = [16, 16, 15, 14, 14, 13, 12, 12, 11, 10, 10, 10]
    for m, r in enumerate(rates):
        for k in range(6):
            e.trend.append((1000 + m * 60 + k * 10, r, 0.2 + m * 0.005))
    tr = e.blink_trend()
    assert tr["ready"] and tr["declining"] and tr["drop_pct"] > 0.3 and tr["blink_duration_change"] > 0


def test_blink_decline_ignores_noise():
    e = engine()
    rates = [14, 16, 13, 15, 14, 16, 13, 15, 14, 16, 13, 15]
    for m, r in enumerate(rates):
        for k in range(6):
            e.trend.append((1000 + m * 60 + k * 10, r, 0.2))
    assert not e.blink_trend()["declining"]


def test_talking_blinks_are_excluded():
    e = engine()
    for i in range(600):  # 60 s at 10 fps
        t = 1000 + i / 10
        e.frames.append((t, True, False, True, i < 300))  # talking in the first half
    for k in range(20):
        e.blinks.append((1000 + k, 0.15, False, True))    # 20 blinks while talking
    for k in range(5):
        e.blinks.append((1040 + k * 3, 0.15, False, False))  # 5 quiet blinks in 30 s
    rate, _, quiet_min = e._blink_stats()
    assert abs(quiet_min - 0.5) < 0.02 and abs(rate - 10) < 0.5


def test_posture_drift_vs_session_start():
    e = engine()
    e.session_start = 1000
    e.distance = 60
    for i in range(400):  # 200 s of upright sitting at 2 Hz -> reference learned after 180 s
        e._posture_sample(1000 + i / 2, 0.0, 0.0, 0.50)
    assert e.posture_ref is not None
    assert e.posture_state(1200)["issues"] == []
    e.distance = 45
    for i in range(80):  # slump + lean in
        e._posture_sample(1200 + i / 2, -15.0, 0.0, 0.60)
    st = e.posture_state(1240)
    assert set(st["issues"]) >= {"slumping", "head_dropping", "leaning_in"}


def test_short_dropout_does_not_reset_sustain(tmp_path):
    s = DB(tmp_path / "t.db").settings()
    t = Triggers()
    close, gone = {"distance_cm": 30, "distance_stale": False}, {"distance_cm": None}
    fired = []
    for i in range(0, 26):  # 25 s close with a 2 s dropout in the middle
        fired += [x["id"] for x in t.evaluate(gone if i in (10, 11) else close, [], s, 1000 + i)]
    assert "too_close" in fired


def test_too_close_skips_global_gap(tmp_path):
    s = DB(tmp_path / "t.db").settings()
    t = Triggers()
    t.last_run = 1000
    t.pending = {"too_close": {"id": "too_close"}}
    assert t.take(1010, False, s)  # 10 s after the last run, still allowed
    t.pending = {"long_stare": {"id": "long_stare"}}
    assert t.take(1020, False, s) is None


def test_conductor_holds_nudges_but_not_priority_ones(tmp_path):
    s = DB(tmp_path / "t.db").settings()
    t = Triggers()
    t.pending = {"low_blink_rate": {"id": "low_blink_rate", "fired_at": 1000}}
    assert t.take(1010, False, s, interruptible=False) is None and "low_blink_rate" in t.pending
    assert t.take(1020, False, s, interruptible=True)          # good moment: it goes out
    t.pending = {"eye_rub": {"id": "eye_rub", "fired_at": 2000}}
    assert t.take(2001, False, s, interruptible=False)         # rubbing can't wait
    t.pending = {"long_stare": {"id": "long_stare", "fired_at": 3000}}
    assert t.take(3000 + 601, False, s, interruptible=True) is None and not t.pending  # held too long: dropped

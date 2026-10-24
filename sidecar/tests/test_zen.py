from eyeos.zen import Zen, eye_score

ENTER = 600


def snap(t, face=True, gaze=True, br=12.0, since_break=None):
    return {"face_present": face, "gaze_on_screen": gaze, "blink_rate": br, "current_stare_s": 5,
            "since_real_break_s": t + 10_000 if since_break is None else since_break}


def run(z, t0, t1, **kw):
    cat = kw.pop("cat", "coding")
    inp = kw.pop("input_age", 2)
    out = []
    for t in range(t0, t1):
        c = z.tick(t, snap(t, **kw), inp, cat, ENTER)
        if c:
            out.append((t, c))
    return out


def test_enters_after_sustained_focus():
    z = Zen()
    ch = run(z, 0, ENTER + 5)
    assert len(ch) == 1 and ch[0][1][0] == "enter" and ch[0][0] >= ENTER * 0.95
    assert z.active and z.source == "auto"


def test_no_entry_when_idle_or_offtask_or_looking_away():
    for kw in ({"input_age": 120}, {"cat": "other"}, {"gaze": False}, {"face": False}):
        z = Zen()
        assert run(z, 0, ENTER + 5, **kw) == [], kw


def test_no_entry_on_call():
    z = Zen()
    run(z, 0, 100, cat="call")
    assert run(z, 100, ENTER + 5) == []


def test_exits_on_idle_switch_and_break():
    z = Zen()
    run(z, 0, ENTER + 5)
    ch = run(z, ENTER + 5, ENTER + 400, input_age=200)
    assert ch[0][1][0] == "exit" and ch[0][1][1]["reason"] == "idle"

    z = Zen()
    run(z, 0, ENTER + 5)
    ch = run(z, ENTER + 5, ENTER + 200, cat="other")
    assert ch[0][1][1]["reason"] == "switched" and ch[0][0] - (ENTER + 5) >= 59

    z = Zen()
    run(z, 0, ENTER + 5)
    ch = run(z, ENTER + 60, ENTER + 70, since_break=1)
    assert ch[0][1][1]["reason"] == "break"


def test_manual_on_ignores_auto_exits_and_manual_off_blocks_reentry():
    z = Zen()
    assert z.set_manual(True, 0)[0] == "enter"
    assert run(z, 0, 300, cat="other", input_age=500) == []
    kind, info = z.set_manual(False, 300)
    assert kind == "exit" and info["reason"] == "manual"
    assert run(z, 300, 300 + ENTER + 5) == []           # suppressed until a break
    run(z, 2000, 2001, since_break=1)                    # real break re-arms
    assert any(c[1][0] == "enter" for c in run(z, 2001, 2001 + ENTER + 5))


def test_recap_stats_and_held_back():
    z = Zen()
    run(z, 0, ENTER + 5, br=6.0)
    z.held_back = 3
    _, info = z.set_manual(False, ENTER + 125)
    assert info["duration_s"] >= 120 and info["blink_rate"] == 6.0 and info["held_back"] == 3


def test_eye_score():
    base = {"face_present": True, "calibrated": True, "blink_rate": 15, "incomplete_pct": 0.1, "current_stare_s": 3,
            "perclos": 0.02, "distance_cm": 60, "since_real_break_s": 100, "squinting": False}
    assert eye_score(base, {"blink_rate": 15}) == 100
    bad = {**base, "blink_rate": 5, "incomplete_pct": 0.6, "current_stare_s": 40, "squinting": True}
    assert eye_score(bad, {"blink_rate": 15}) < 50
    assert eye_score({**base, "face_present": False}, {}) is None

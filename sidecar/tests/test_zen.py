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


def test_recap_stats_summarizes_the_session():
    from eyeos.zen import recap_stats
    rows = []
    for i in range(600):  # 10 min: blinking slides 16 -> 10, 3 min too close, some posture drift
        rows.append({"blink_rate": 16 - 6 * i / 600, "distance_cm": 32 if 200 <= i < 380 else 60,
                     "posture_issues": ["slumping"] if i > 500 else [], "eye_score": 70, "current_stare_s": 8})
    events = [{"kind": "rub", "trigger_id": None, "value": None}] * 2 + \
             [{"kind": "trigger", "trigger_id": "too_close", "value": 32}] * 3 + \
             [{"kind": "trigger", "trigger_id": "heartbeat", "value": None}]
    s = recap_stats(rows, events, base_blink=15)
    assert s["rubs"] == 2 and s["too_close_s"] == 180 and s["posture_off_s"] == 99
    assert s["blink_change_pct"] <= -25 and s["alerts_held"] == {"too_close": 3}
    texts = [h["text"] for h in s["highlights"]]
    assert texts[0].startswith("Blinking slowed") and any("Rubbed your eyes 2 times" in t for t in texts)
    assert any("Too close to the screen for 3 min" in t for t in texts)
    assert any("3 alerts held back: too close to the screen ×3" in t for t in texts)


def test_recap_stats_empty_session():
    from eyeos.zen import recap_stats
    s = recap_stats([], [], base_blink=None)
    assert s["highlights"] == [] and s["alerts_held_total"] == 0


def conductor_run(z, t0, t1, decide, cat="other", input_age=2):
    """Tick 1 Hz; every 30 s the conductor adds a decision from decide(t)."""
    hist, out = [], []
    for t in range(t0, t1):
        if t % 30 == 0:
            hist.append({"ts": t, **decide(t)})
        c = z.tick(t, snap(t), input_age, cat, ENTER, conductor=hist[-5:])
        if c:
            out.append((t, c))
    return out


def test_conductor_deep_focus_enters_even_in_a_browser():
    z = Zen()  # category "other" would block the old rule; the conductor sees deep work
    ch = conductor_run(z, 0, ENTER + 5, lambda t: {"focus": "deep", "situation": "deep_work"})
    assert ch and ch[0][1][0] == "enter"


def test_conductor_casual_blocks_entry_even_in_vs_code():
    z = Zen()
    assert conductor_run(z, 0, ENTER + 200, lambda t: {"focus": "light", "situation": "casual"}, cat="coding") == []


def test_conductor_exits_when_focus_ends_and_on_meetings():
    z = Zen()
    ch = conductor_run(z, 0, ENTER + 400, lambda t: {"focus": "deep" if t < ENTER + 100 else "none", "situation": "casual"})
    assert [c[1][0] for c in ch] == ["enter", "exit"] and ch[1][1][1]["reason"] == "focus_ended"
    z = Zen()
    ch = conductor_run(z, 0, ENTER + 200, lambda t: {"focus": "deep", "situation": "meeting" if t > ENTER + 60 else "deep_work"})
    assert ch[-1][1][1]["reason"] == "call"


def test_quick_manual_exit_makes_entry_stricter():
    z = Zen()
    conductor_run(z, 0, ENTER + 5, lambda t: {"focus": "deep", "situation": "deep_work"})
    assert z.active
    z.set_manual(False, ENTER + 30)
    assert z.quick_exits == 1

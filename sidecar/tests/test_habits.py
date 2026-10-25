import math

from eyeos import metrics as M
from tests.test_metrics import _synth_face

W, H = 640, 480
# _synth_face: eye centres at (280, 240) and (360, 240) px, outer corners 110 px apart (1 IOD), bridge at (320, 240)


def hand_at(x, y):
    """21 hand points at (x, y) px."""
    return [[x / W, y / H, 0]] * 21


def feed(eng, t0, seconds, where, eyes=lambda s: 1.0, fps=30):
    """Face visible with eye openness `eyes(s)`; hands only every 3rd frame, as in vision.py."""
    evs = []
    n = int(seconds * fps)
    for i in range(n):
        t = t0 + i / fps
        hands = None
        if i % 3 == 0:
            hand = where(t - t0)
            hands = [hand] if hand else []
        evs += eng.update({"ts": t, "w": W, "h": H, "face": _synth_face(eyes(t - t0)), "blend": {}, "transform": None,
                           "hands": hands, "luma": 100.0})
    return evs, t0 + n / fps


def kinds(evs, k):
    return [e for e in evs if e["kind"] == k]


def wobble(x, y, amp, hz=3):
    """A fingertip moving back and forth at the eye (a rub), `amp` px each way."""
    return lambda s: hand_at(x + amp * math.sin(2 * math.pi * hz * s), y)


# ---------- touches at the eyes ----------

def test_a_rub_is_cued_within_a_moment_of_the_eyes_closing():
    eng = M.Engine()
    # hand arrives at 0.5 s and rubs; the eye closes as it lands
    evs, _ = feed(eng, 0.0, 2.0, lambda s: None if s < 0.5 else wobble(282, 244, 20)(s), eyes=lambda s: 1.0 if s < 0.5 else 0.3)
    touch, rub = kinds(evs, "touch"), kinds(evs, "rub")
    assert len(touch) == 1 and len(rub) == 1 and not kinds(evs, "lash_pull")
    assert 0.6 <= touch[0]["ts"] <= 0.75 and touch[0]["ts"] < rub[0]["ts"]


def test_a_held_touch_that_stays_put_with_closed_eyes_is_a_lash_pull():
    eng = M.Engine()
    evs, _ = feed(eng, 0.0, 2.0, lambda s: None if s < 0.5 else wobble(282, 236, 1)(s), eyes=lambda s: 1.0 if s < 0.5 else 0.3)
    assert len(kinds(evs, "touch")) == 1 and len(kinds(evs, "lash_pull")) == 1 and not kinds(evs, "rub")


def test_hands_at_open_eyes_are_never_a_touch():
    # twirling hair in front of the eyes, a cheek or chin rest, pushing up glasses: the eyes stay open
    for name, where in {"hair in front of the eye": wobble(282, 240, 15),
                        "cheek rest": lambda s: hand_at(280, 270),
                        "glasses at the bridge": lambda s: hand_at(306, 240)}.items():
        evs, _ = feed(M.Engine(), 0.0, 3.0, where)
        assert not kinds(evs, "touch") and not kinds(evs, "rub") and not kinds(evs, "lash_pull"), name


def test_a_blink_with_a_hand_nearby_is_not_a_touch():
    eng = M.Engine()
    evs, _ = feed(eng, 0.0, 3.0, lambda s: hand_at(280, 270), eyes=lambda s: 0.2 if 1.0 <= s < 1.1 else 1.0)
    assert not kinds(evs, "touch")


def test_glasses_with_closed_eyes_are_still_not_a_touch():
    evs, _ = feed(M.Engine(), 0.0, 3.0, lambda s: hand_at(306, 240), eyes=lambda s: 0.3)
    assert not kinds(evs, "touch") and not kinds(evs, "rub")


def test_one_cue_per_ten_seconds():
    eng = M.Engine()
    evs, t = [], 0.0
    for _ in range(2):  # two rubs 3 s apart
        e, t = feed(eng, t, 3.0, lambda s: None if s < 1.5 else wobble(282, 244, 12)(s),
                    eyes=lambda s: 1.0 if s < 1.5 else 0.3)
        evs += e
    assert len(kinds(evs, "touch")) == 1


def test_a_hand_near_the_eyes_makes_hands_checked_every_frame():
    eng = M.Engine()
    feed(eng, 0.0, 0.5, lambda s: hand_at(300, 300))
    assert eng.hands_hot_until > 0.5 and eng.snapshot()["hand_eye_r"] < 1.0
    eng = M.Engine()
    feed(eng, 0.0, 0.5, lambda s: hand_at(320, 470))  # at the bottom of the frame
    assert eng.hands_hot_until == 0.0


# ---------- coach ----------

from eyeos import habits as Hb  # noqa: E402


def test_coach_cues_touches_unless_silenced():
    c = Hb.HabitCoach()
    assert c.on_touch(True) and not c.on_touch(False)


def test_swap_offers_are_spaced_and_stop_after_three_noes():
    c = Hb.HabitCoach()
    assert c.on_habit(0, True, False, "d1") is True
    assert c.on_habit(100, True, False, "d1") is False              # within 5 min
    assert c.on_habit(50, True, True, "d1") is True                 # demo: 45 s apart
    assert c.on_habit(10_000, False, False, "d1") is False          # silenced (Zen, call...)
    for _ in range(3):
        c.answered("Not now", "d1")
    assert c.on_habit(20_000, True, False, "d1") is False           # three noes today
    assert c.on_habit(30_000, True, False, "d2") is True            # a new day
    c.answered(None, "d2")                                          # ignored isn't a no
    assert c.declines.get("d2", 0) == 0


# ---------- lean lens ----------

def lens_run(dist_at, seconds=60, **kw):
    lens, out = Hb.LeanLens(), []
    for i in range(seconds * 5):
        t = i / 5
        out.append(lens.update(t, dist_at(t), 60, kw.get("stale", False), kw.get("allowed", True), kw.get("demo", False)))
    return lens, out


def test_lens_fades_in_after_leaning_in_for_30_s():
    _, out = lens_run(lambda t: 40)
    assert out[5 * 29] == 0 and 0 < out[5 * 38] < 1 and out[5 * 46] == 1


def test_lens_clears_only_once_you_sit_back_past_the_band():
    _, out = lens_run(lambda t: 40 if t < 50 else 51)        # 51 cm is between 0.8x and 0.88x of 60: still close
    assert out[-1] == 1
    _, out = lens_run(lambda t: 40 if t < 50 else 56)        # 56 > 0.88 x 60: sat back
    assert out[-1] == 0


def test_lens_is_off_when_not_allowed_or_distance_is_stale():
    assert max(lens_run(lambda t: 40, allowed=False)[1]) == 0
    assert max(lens_run(lambda t: 40, stale=True)[1]) == 0
    assert lens_run(lambda t: 40, seconds=20, demo=True)[1][-1] == 1  # demo: full by 15 s


def test_lens_holds_while_bigger_text_gets_a_chance():
    lens = Hb.LeanLens()
    for i in range(50 * 5):
        lens.update(i / 5, 40, 60, False, True)
    lens.hold(50)
    assert lens.update(80, 40, 60, False, True) == 0 and lens.update(111, 40, 60, False, True) == 1


# ---------- squint zoom ----------

def test_zoom_offered_for_squinting_in_text_apps_once_per_ten_minutes():
    z = Hb.ZoomCoach()
    assert not z.want(0, "com.apple.Safari", "reading", 3, False, True)      # not long enough
    assert not z.want(0, "com.spotify", "other", 30, False, True)           # Cmd+ doesn't zoom there
    assert not z.want(0, "com.apple.Safari", "reading", 30, False, False)   # silenced
    assert z.want(0, "com.apple.Safari", "reading", 30, False, True)
    assert not z.want(300, "com.apple.Safari", "reading", 30, False, True)  # same app, too soon
    assert z.want(300, "com.microsoft.VSCode", "coding", 0, True, True)     # leaning in at small text, another app
    assert z.want(700, "com.apple.Safari", "reading", 30, False, True)


# ---------- triggers ----------

BASE = {k: 0.2 for k, *_ in Hb.CONDITIONS}


def test_finds_what_comes_before_a_habit():
    ctxs = [{"since_real_break_s": 3600, "hour": 10}] * 7 + [{"since_real_break_s": 600, "hour": 10}] * 2
    found = Hb.habit_triggers(ctxs, BASE, baseline=15)
    assert found[0]["key"] == "no_break" and (found[0]["k"], found[0]["n"]) == (7, 9) and found[0]["lift"] == 3.9


def test_no_trigger_from_an_even_spread_or_too_few():
    assert Hb.habit_triggers([{"since_real_break_s": 3600}] * 2, BASE, 15) == []
    even = [{"since_real_break_s": 3600}] * 2 + [{"since_real_break_s": 60}] * 8  # 20 % at rub time = 20 % overall
    assert Hb.habit_triggers(even, BASE, 15) == []


def test_low_blink_needs_a_baseline():
    ctxs = [{"blink_rate": 5}] * 5
    assert [f["key"] for f in Hb.habit_triggers(ctxs, BASE, 15)] == ["low_blink"]
    assert Hb.habit_triggers(ctxs, BASE, None) == []


# ---------- learning ----------

def test_learning_turns_habit_triggers_into_memory_rules(tmp_path):
    import json
    import time
    from eyeos import learning
    from eyeos.db import DB
    db, now = DB(tmp_path / "t.db"), time.time()
    for i in range(100):  # an hour of screen time, mostly with recent breaks
        db.x("INSERT INTO metrics_1hz (ts, data) VALUES (?, ?)",
             (now - 3600 + i * 30, json.dumps({"face_present": True, "since_real_break_s": 3000 if i < 10 else 300})))
    for i in range(5):
        db.x("INSERT INTO events (ts, kind, details) VALUES (?, 'rub', ?)",
             (now - 600 + i, json.dumps({"event": "rub", "context": {"since_real_break_s": 3200, "hour": 10}})))
    rules = learning.derive(db, now=now)
    assert rules["habit:rub:no_break"].startswith("Most of this user's eye rubs (5 of 5 recently) come after 45+ min")
    assert "habit:rub:no_break" not in learning.derive(db, now=now, suppressed=["habit:rub:no_break"])

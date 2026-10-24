import math
import random

from eyeos import gym as G
from eyeos.agent import exercise_steps
from eyeos.blur import StareBlur, ramp


def make(kind, duration=30):
    return G.Gym(kind, exercise_steps(kind, duration), 0.0)


def ev(kind):
    return {"kind": kind, "ts": 0}


# ---------- deliberate_blink ----------

def test_counts_full_blinks_aloud_and_calls_out_half_ones():
    g = make("deliberate_blink")
    assert g.feed_events([ev("blink")], 1) == "One."
    assert g.feed_events([ev("eyes_closed")], 2) == "Two."  # a long squeeze still counts
    assert g.feed_events([ev("incomplete")], 3) == G.PHRASES["half"]
    assert g.feed_events([ev("incomplete")], 4) is None    # cooldown
    assert g.feed_events([ev("incomplete")], 3 + G.COOLDOWN_S["half"]) == G.PHRASES["half"]
    assert (g.full, g.half) == (2, 3)
    assert g.result() == {"score": 40, "summary": "2 full blinks · 3 half", "full": 2, "half": 3}


def test_stops_counting_aloud_past_the_target():
    g = make("deliberate_blink")
    said = [g.feed_events([ev("blink")], 1 + i) for i in range(G.TARGET_BLINKS + 2)]
    assert said[G.TARGET_BLINKS - 1].startswith("Ten.") and said[-1] is None and g.full == G.TARGET_BLINKS + 2


def test_other_exercises_ignore_blinks():
    g = make("palming")
    assert g.feed_events([ev("blink")], 1) is None and g.full == 0


# ---------- palming ----------

def run_palming(open_at):
    """5 Hz over a 30 s palming; eyes open whenever open_at(t)."""
    g = make("palming")
    said = []
    for i in range(30 * 5):
        t = i / 5
        is_open = open_at(t)
        snap = {"face_present": is_open, "o": 0.9 if is_open else None, "rubbing": False}
        r = g.tick(t, snap)
        if r:
            said.append((t, r))
    return g, said


def test_palming_with_eyes_covered_scores_full():
    g, said = run_palming(lambda t: False)
    assert said == [] and g.score() == 100


def test_peeking_is_caught_and_lowers_the_score():
    g, said = run_palming(lambda t: 14 <= t < 17)
    assert len(said) == 1 and said[0][1] == G.PHRASES["peek"] and 15.4 <= said[0][0] <= 15.8
    assert 80 <= g.score() < 100


def test_open_eyes_outside_the_checked_steps_dont_count():
    g, said = run_palming(lambda t: t < 6 or t > 28)  # step 1 (warm palms) and the last step (open slowly)
    assert said == [] and g.score() == 100


def test_blinking_while_peeking_is_still_peeking():
    g, said = run_palming(lambda t: (t * 5) % 15 != 0)  # eyes open, one 0.2 s blink every 3 s
    assert said and g.score() < 10


def test_peeking_stays_up_through_a_blink():
    g = make("palming")
    for i in range(50):
        t = 10 + i / 5
        g.tick(t, {"face_present": True, "o": 0.1 if i == 20 else 0.9})
        if i >= 20:
            assert g.peeking, t


def test_a_real_closure_ends_peeking():
    g = make("palming")
    for i in range(20):
        g.tick(10 + i / 5, {"face_present": True, "o": 0.9})
    assert g.peeking
    for i in range(5):
        g.tick(14 + i / 5, {"face_present": True, "o": 0.1})
    assert not g.peeking


def test_hands_at_the_eyes_count_as_covered_unless_eyes_are_wide_open():
    g = make("palming")
    for i in range(100):
        g.tick(10 + i / 5, {"face_present": True, "o": 0.6, "rubbing": True})  # palm over a closed eye: unclear reading
    assert g.score() == 100 and not g.peeking
    g = make("palming")
    for i in range(60):  # stays inside the checked steps (they end at 25.5 s)
        g.tick(10 + i / 5, {"face_present": True, "o": 0.95, "rubbing": True})  # peeking between the fingers
    assert g.score() == 0 and g.peeking


# ---------- gaze_trace ----------

def run_gaze(gx_at, yaw_at=lambda t: 0.0, seconds=30):
    g = make("gaze_trace", seconds)
    said = []
    for i in range(seconds * 5):
        t = i / 5
        r = g.tick(t, {"face_present": True, "o": 0.9, "gx": gx_at(t), "yaw_deg": yaw_at(t)})
        if r:
            said.append(r)
    return g, said


def test_following_the_dot_scores_high_even_mirrored_and_scaled():
    rnd = random.Random(1)
    g, said = run_gaze(lambda t: 0.5 - 0.08 * G.dot(t - 0.2)[0] + rnd.gauss(0, 0.01))  # lag, mirror, small range, noise
    assert g.score() > 80 and G.PHRASES["on_it"] in said


def test_not_following_scores_low():
    rnd = random.Random(2)
    g, said = run_gaze(lambda t: 0.5 + rnd.gauss(0, 0.02))
    assert g.score() < 30 and G.PHRASES["catch_up"] in said


def test_turning_the_head_instead_of_the_eyes_is_called_out():
    rnd = random.Random(3)
    g, said = run_gaze(lambda t: 0.5 + rnd.gauss(0, 0.02), yaw_at=lambda t: 15 * G.dot(t)[0])
    assert G.PHRASES["head"] in said


def test_blinks_dont_pollute_gaze():
    g = make("gaze_trace")
    for i in range(200):
        t = i / 5
        g.tick(t, {"face_present": True, "o": 0.1, "gx": 0.9, "yaw_deg": 0})
    assert g.accuracy is None and g.score() is None and g.summary() == "Nice work."


def test_dot_is_a_horizontal_figure_eight():
    xs = [G.dot(i / 10)[0] for i in range(60)]
    ys = [G.dot(i / 10)[1] for i in range(60)]
    assert max(xs) > 0.99 and min(xs) < -0.99 and max(abs(y) for y in ys) <= 0.35 + 1e-9
    assert math.isclose(G.dot(0)[0], G.dot(G.PERIOD_S)[0], abs_tol=1e-9)


def test_unchecked_exercise_reports_progress():
    g = make("focus_shift")
    assert g.tick(5, {"face_present": True}) is None
    p = g.progress(5)
    assert p["kind"] == "focus_shift" and p["checking"] is False and p["summary"] == "Nice work."


# ---------- blink-to-unblur ----------

def test_ramp_eases_between_start_and_full():
    assert ramp(0, 8, 20) == 0 and ramp(8, 8, 20) == 0 and ramp(20, 8, 20) == 1 and ramp(99, 8, 20) == 1
    assert ramp(14, 8, 20) == 0.5 and 0 < ramp(10, 8, 20) < 0.5


def test_full_blink_clears_half_blink_halves():
    b = StareBlur()
    assert b.update(20, True, 8, 20, 0.8) == 0.8
    b.on_dip("incomplete")
    assert b.update(0, True, 8, 20, 0.8) == 0.4   # stare resets, but half the blur stays
    assert b.update(14, True, 8, 20, 0.8) == 0.4  # until the ramp passes it
    assert b.update(18, True, 8, 20, 0.8) > 0.4
    b.on_dip("blink")
    assert b.update(0, True, 8, 20, 0.8) == 0


def test_blur_off_when_not_allowed():
    b = StareBlur()
    b.update(30, True, 8, 20, 1.0)
    b.on_dip("incomplete")
    assert b.update(30, False, 8, 20, 1.0) == 0
    assert b.update(0, True, 8, 20, 1.0) == 0  # the half-blink leftover doesn't come back

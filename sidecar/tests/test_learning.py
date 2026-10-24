import json
import time

from eyeos import learning
from eyeos.db import DB


def call(db, name, approval="approved", status="done", result=None, ts=None):
    return db.x("INSERT INTO tool_calls (run_id, ts, name, args, status, approval, result) VALUES (1, ?, ?, '{}', ?, ?, ?)",
                (ts or time.time(), name, status, approval, json.dumps(result) if result is not None else None))


def outcome(db, cid, verdict, metric="blink_rate", ts=None):
    db.x("INSERT INTO outcomes (call_id, ts, metric, verdict) VALUES (?, ?, ?, ?)", (cid, ts or time.time(), metric, verdict))


def test_learns_what_helps_and_what_does_not(tmp_path):
    db = DB(tmp_path / "t.db")
    for v in ("improved", "improved", "neutral", "improved"):
        outcome(db, call(db, "remind_to_blink"), v)
    for v in ("neutral", "worse", "neutral"):
        outcome(db, call(db, "play_ambient_cue"), v)
    rules = learning.derive(db)
    assert "tends to help" in rules["effect:remind_to_blink"] and "3 of 4" in rules["effect:remind_to_blink"]
    assert "rarely helps" in rules["effect:play_ambient_cue"]


def test_too_little_evidence_and_old_exercise_verdicts_ignored(tmp_path):
    db = DB(tmp_path / "t.db")
    outcome(db, call(db, "remind_to_blink"), "improved")
    for _ in range(4):  # the old, wrong "did you look away" scoring for exercises
        outcome(db, call(db, "start_guided_eye_exercise"), "no_break", metric="since_real_break_s")
    assert learning.derive(db) == {}


def test_declines_and_not_now_answers(tmp_path):
    db = DB(tmp_path / "t.db")
    call(db, "start_guided_eye_exercise", approval="declined", status="declined")
    call(db, "start_guided_eye_exercise", approval="declined", status="declined")
    db.set_approval("set_dark_mode", "declined")
    for choice in ("Not now", "No thanks", "Yes, start"):
        call(db, "ask_user", approval="never_asked", result={"choice": choice})
    rules = learning.derive(db)
    assert "declined guided eye exercises (2 times)" in rules["decline:start_guided_eye_exercise"]
    assert "decline:set_dark_mode" in rules
    assert "2 of 3" in rules["ask:negative"]


def test_apply_upserts_and_removes(tmp_path):
    db = DB(tmp_path / "t.db")
    assert learning.apply(db, {"effect:x": "X helps (3 of 4)"}) == ["effect:x"]
    assert learning.apply(db, {"effect:x": "X helps (4 of 5)"}) == []
    assert [p["rule"] for p in db.preferences()] == ["X helps (4 of 5)"]
    learning.apply(db, {})
    assert db.preferences() == []
    db.add_preference("Never change dark mode in Figma")  # the agent's own rules are never touched
    learning.apply(db, {})
    assert len(db.preferences()) == 1


def test_evidence_before_a_memory_reset_is_ignored(tmp_path):
    db = DB(tmp_path / "t.db")
    for v in ("improved", "improved", "improved"):
        outcome(db, call(db, "remind_to_blink"), v)
    db.set_approval("set_dark_mode", "declined")
    reset_at = time.time() + 1
    assert learning.derive(db, now=reset_at + 60, reset_at=reset_at) == {}
    for v in ("improved", "improved", "improved"):
        outcome(db, call(db, "remind_to_blink", ts=reset_at + 10), v, ts=reset_at + 20)
    assert list(learning.derive(db, now=reset_at + 60, reset_at=reset_at)) == ["effect:remind_to_blink"]


def test_suppressed_keys_are_not_relearned(tmp_path):
    db = DB(tmp_path / "t.db")
    db.set_approval("set_dark_mode", "declined")
    assert "decline:set_dark_mode" not in learning.derive(db, suppressed=["decline:set_dark_mode"])

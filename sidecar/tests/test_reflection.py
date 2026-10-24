import json
import time

from eyeos import reflection as R
from eyeos.db import DB


def seed(db, start, minutes, blink=12.0, situation="deep_work"):
    for i in range(minutes * 60):
        ts = start + i
        db.x("INSERT INTO metrics_1hz (ts, data) VALUES (?, ?)", (ts, json.dumps({"blink_rate": blink, "eye_score": 70})))
    db.x("INSERT INTO conductor_log (ts, data) VALUES (?, ?)", (start, json.dumps({"situation": situation})))


def test_due_needs_enough_unreflected_screen_time(tmp_path):
    db = DB(tmp_path / "t.db")
    now = time.time()
    seed(db, now - 3600, 20)
    assert R.due(db, now)[0] is False
    seed(db, now - 1800, 20)
    ok, since = R.due(db, now)
    assert ok and since < now - 3600
    R.save(db, since, now, "test", {"summary": "s", "rules": []}, {})
    assert R.due(db, now + 60)[0] is False  # just reflected


def test_gather_groups_by_situation_and_parse_saves_rules(tmp_path):
    db = DB(tmp_path / "t.db")
    now = time.time()
    seed(db, now - 7200, 30, blink=8, situation="deep_work")
    seed(db, now - 3600, 30, blink=16, situation="casual")
    g = R.gather(db, now - 8000, now)
    assert g["by_situation"]["deep_work"]["avg_blink_rate"] == 8 and g["by_situation"]["casual"]["avg_blink_rate"] == 16
    res = R.parse('Here you go: {"summary": "Deep work halves your blinking.", "rules": '
                  '[{"rule": "During deep work, prefer the silent edge glow", "evidence": "8 vs 16/min"}], "try_next": "x"}')
    R.save(db, now - 8000, now, "test", res, g)
    assert [p["rule"] for p in db.preferences() if p["source"] == "reflection"] == ["During deep work, prefer the silent edge glow"]
    R.save(db, now, now + 1, "test", {"summary": "", "rules": []}, {})
    assert not [p for p in db.preferences() if p["source"] == "reflection"]  # replaced each time

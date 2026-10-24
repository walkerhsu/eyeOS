import asyncio
import json
import time

from eyeos import server
from tests.test_commands import make
from tests.test_metrics import _feed


def calibrate(app, step, o_fn, seconds):
    """Run a calibration step, feeding synthetic frames once it starts recording."""
    async def go():
        app.loop = asyncio.get_running_loop()
        task = asyncio.create_task(app.calibrate(step, {}))
        while app.engine.recorder is None:
            await asyncio.sleep(0.01)
        _feed(app.engine, time.time(), seconds, o_fn)
        await task
    asyncio.run(go())
    return [m for m in app.sent if m.get("type") == "calibration"][-1]


def quick_blinks(depth, at=(1.0, 2.0, 3.0)):
    return lambda s: depth if any(b <= s < b + 0.13 for b in at) else 1.0


def test_blink_check_sets_thresholds_and_ends_early(tmp_path):
    app = make(tmp_path)
    t0 = time.time()
    m = calibrate(app, server.BLINK_CHECK, quick_blinks(0.3), 4.0)
    assert m["phase"] == "done" and m["blinks"] == 3 and m["warnings"] == []
    assert time.time() - t0 < 2  # didn't wait out the 8 s
    assert app.engine.cal["complete_o"] == 0.44 and app.engine.cal["incomplete_max_o"] == 0.70
    row = json.loads(app.db.q("SELECT data FROM calibration ORDER BY id DESC LIMIT 1")[0]["data"])
    assert [d["kind"] for d in row["dips"]] == ["blink"] * 3


def test_blink_check_fails_without_blinks_and_keeps_old_thresholds(tmp_path, monkeypatch):
    monkeypatch.setitem(server.CAL_SECONDS, server.BLINK_CHECK, 0.5)
    app = make(tmp_path)
    m = calibrate(app, server.BLINK_CHECK, lambda s: 1.0, 4.0)
    assert m["phase"] == "failed" and "didn't see your blinks" in m["result"]["reason"]
    assert "complete_o" not in app.engine.cal
    ev = json.loads(app.db.q("SELECT details FROM events ORDER BY id DESC LIMIT 1")[0]["details"])
    assert ev["event"] == "calibration_failed" and ev["dips"] == [] and ev["fps"] > 25


def test_blink_check_warns_when_one_blink_is_missing(tmp_path, monkeypatch):
    monkeypatch.setitem(server.CAL_SECONDS, server.BLINK_CHECK, 0.5)
    app = make(tmp_path)
    m = calibrate(app, server.BLINK_CHECK, quick_blinks(0.3, at=(1.0, 2.0)), 4.0)
    assert m["phase"] == "done" and m["blinks"] == 2
    assert m["warnings"] == ["We only saw 2 of the 3 blinks."]


def test_baseline_counts_full_and_half_blinks(tmp_path, monkeypatch):
    monkeypatch.setitem(server.CAL_SECONDS, 3, 0.5)
    app = make(tmp_path)
    app.engine.set_cal({"complete_o": 0.44, "incomplete_max_o": 0.70})  # from a blink check
    # a natural blink to 0.4, a half blink to 0.6, and a slow glance down that isn't a blink
    o = lambda s: 0.4 if 1.0 <= s < 1.13 else 0.6 if 2.0 <= s < 2.13 else 0.6 if 3.0 <= s < 3.8 else 1.0
    m = calibrate(app, 3, o, 5.0)
    assert m["phase"] == "done"
    row = json.loads(app.db.q("SELECT data FROM calibration ORDER BY id DESC LIMIT 1")[0]["data"])
    assert [d["kind"] for d in row["dips"]] == ["blink", "incomplete"]
    assert "We didn't catch many blinks." in row["warnings"]

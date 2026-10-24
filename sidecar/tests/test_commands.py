import asyncio

from eyeos.server import App


def make(tmp_path):
    app = App(db_path=tmp_path / "t.db")
    app.sent, app.ui = [], []

    async def send(m):
        app.sent.append(m)

    async def ui_request(kind, payload, timeout):
        app.ui.append((kind, payload))
        return {"dismissed_by": "timer"}
    app.send, app.ui_request = send, ui_request
    return app


def run(app, *cmds, wait=0.0):
    async def go():
        app.loop = asyncio.get_running_loop()
        for name, args in cmds:
            await app.command(name, args)
        await asyncio.sleep(wait)
    asyncio.run(go())


def test_timed_pause_resumes_itself(tmp_path):
    app = make(tmp_path)
    run(app, ("pause", {"minutes": 0.001}), wait=0.2)
    assert app.settings["tracking.paused"] is False
    assert app.paused_until is None and app.resume_timer is None


def test_manual_resume_cancels_the_timer(tmp_path):
    app = make(tmp_path)
    run(app, ("pause", {"minutes": 30}))
    assert app.settings["tracking.paused"] is True and app.paused_until is not None
    run(app, ("resume", {}))
    assert app.settings["tracking.paused"] is False and app.paused_until is None


def test_plain_pause_has_no_deadline(tmp_path):
    app = make(tmp_path)
    run(app, ("pause", {}))
    assert app.settings["tracking.paused"] is True and app.paused_until is None


def test_break_now_shows_the_look_away_card(tmp_path):
    app = make(tmp_path)
    run(app, ("break_now", {}), wait=0.05)
    assert app.ui and app.ui[0][0] == "look_away_card" and app.ui[0][1]["duration_s"] == 20
    events = app.db.q("SELECT details FROM events WHERE kind='system'")
    assert any("break_now" in (e["details"] or "") for e in events)

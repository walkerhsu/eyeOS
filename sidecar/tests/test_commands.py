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


def quiet_exercises(app):
    async def no_voice(steps, kind=None):
        pass
    app.agent._narrate = no_voice  # don't speak during tests


def test_user_exercise_runs_and_is_logged_as_the_users(tmp_path):
    app = make(tmp_path)
    quiet_exercises(app)
    run(app, ("exercise", {"type": "deliberate_blink", "duration_s": 30}), wait=0.05)
    assert app.ui and app.ui[0][0] == "exercise" and app.ui[0][1]["type"] == "deliberate_blink"
    assert sum(s["seconds"] for s in app.ui[0][1]["steps"]) == 30
    row = app.db.q("SELECT run_id, name, status, approval FROM tool_calls")[0]
    assert row == {"run_id": None, "name": "start_guided_eye_exercise", "status": "done", "approval": "user_started"}


def test_agent_sees_user_exercises_as_the_users(tmp_path):
    app = make(tmp_path)
    quiet_exercises(app)
    run(app, ("exercise", {"type": "palming"}), wait=0.05)
    assert app.ui[0][1]["duration_s"] == 30  # default length

    async def ctx():
        return await app.agent.context([])
    recent = asyncio.run(ctx())["recent_actions"]
    assert recent[-1]["tool"] == "start_guided_eye_exercise" and recent[-1]["started_by"] == "user"


def test_unknown_exercise_is_rejected(tmp_path):
    app = make(tmp_path)
    run(app, ("exercise", {"type": "jumping_jacks"}))
    assert not app.ui and any(m.get("code") == "bad_exercise" for m in app.sent)
    assert app.db.q("SELECT COUNT(*) n FROM tool_calls")[0]["n"] == 0

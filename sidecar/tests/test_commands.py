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
    app.speaker.prewarm = lambda texts: None


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


def test_gaze_trace_runs_and_its_result_is_logged(tmp_path):
    app = make(tmp_path)
    quiet_exercises(app)
    run(app, ("exercise", {"type": "gaze_trace", "duration_s": 30}), wait=0.05)
    assert app.ui[0][0] == "exercise" and app.ui[0][1]["type"] == "gaze_trace" and app.gym is None
    res = [e for e in app.db.q("SELECT details FROM events WHERE kind='system'") if "exercise_result" in e["details"]]
    assert len(res) == 1 and '"type": "gaze_trace"' in res[0]["details"]
    assert "gaze_trace exercise (30 s)" in app.db.q("SELECT result FROM tool_calls")[0]["result"]


def test_agent_can_tune_blink_blur(tmp_path):
    app = make(tmp_path)

    async def go(args):
        app.loop = asyncio.get_running_loop()
        return await app.agent.execute("set_blink_blur", args, None)
    ok, r = asyncio.run(go({"enabled": True, "strength": 0.4}))
    assert ok and r == "blink blur on at 40%" and app.settings["blur.enabled"] is True and app.settings["blur.strength"] == 0.4
    ok, r = asyncio.run(go({"enabled": False}))
    assert ok and r == "blink blur off" and app.settings["blur.enabled"] is False and app.settings["blur.strength"] == 0.4


def test_a_rub_offers_palming_and_accepting_starts_it(tmp_path):
    app = make(tmp_path)
    quiet_exercises(app)
    answers = iter([{"choice": "Palm 20 s"}])

    async def ui_request(kind, payload, timeout):
        app.ui.append((kind, payload))
        return next(answers) if kind == "ask_user" else {"completed": True}
    app.ui_request = ui_request

    async def go():
        app.loop = asyncio.get_running_loop()
        app.on_events([{"kind": "rub", "ts": 1.0}])
        await asyncio.sleep(0.1)
    asyncio.run(go())
    kinds = [k for k, _ in app.ui]
    assert kinds[:2] == ["ask_user", "exercise"] and app.ui[0][1]["question"].startswith("Itchy eyes?")
    assert app.ui[1][1]["type"] == "palming" and app.ui[1][1]["duration_s"] == 20
    rub = app.db.q("SELECT details FROM events WHERE kind='rub'")[0]
    assert '"context"' in rub["details"]
    swaps = [e for e in app.db.q("SELECT details FROM events WHERE kind='system'") if "habit_swap" in e["details"]]
    assert len(swaps) == 1 and '"accepted": true' in swaps[0]["details"]


def test_habits_stay_silent_in_zen_but_are_counted(tmp_path):
    app = make(tmp_path)
    app.zen.set_manual(True, 0)

    async def go():
        app.loop = asyncio.get_running_loop()
        app.on_events([{"kind": "touch", "ts": 1.0}, {"kind": "rub", "ts": 1.2}])
        await asyncio.sleep(0.05)
    asyncio.run(go())
    assert app.ui == [] and not any(m.get("type") == "habit_cue" for m in app.sent)
    assert app.db.q("SELECT COUNT(*) n FROM events WHERE kind='rub'")[0]["n"] == 1


def test_a_touch_sends_the_cue(tmp_path):
    app = make(tmp_path)

    async def go():
        app.loop = asyncio.get_running_loop()
        app.on_events([{"kind": "touch", "ts": 1.0}])
        await asyncio.sleep(0.05)
    asyncio.run(go())
    assert [m["style"] for m in app.sent if m.get("type") == "habit_cue"] == ["glow+sound"]
    assert app.db.q("SELECT COUNT(*) n FROM events WHERE kind='touch'")[0]["n"] == 1

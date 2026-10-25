import asyncio
import os

from eyeos.agent import Agent
from eyeos.db import DB
from eyeos.zen import Zen


class FakeApp:
    def __init__(self, tmp_path, answer):
        self.db = DB(tmp_path / "t.db")
        self.settings = self.db.settings()
        self.active = {"name": "Safari", "bundle_id": "com.apple.Safari", "window_title": "x", "category": "reading"}
        self.answer = answer
        self.asked, self.sent, self.ui = [], [], []
        self.last_action = None
        self.zen = Zen()

    async def send(self, m):
        self.sent.append(m)

    async def send_approvals(self):
        pass

    async def send_preferences(self):
        pass

    async def notice(self, text):
        pass

    async def ui_request(self, kind, payload, timeout):
        if kind == "approval":
            self.asked.append(payload["tool"])
            return self.answer
        self.ui.append(kind)
        return {"shown": True}

    def refresh_screen_soon(self):
        pass


def call(app, name, args):
    os.environ.setdefault("ANTHROPIC_API_KEY", "test")
    agent = Agent(app)
    executed = []

    async def fake_exec(n, a, row):
        executed.append(n)
        return True, "ok"
    agent.execute = fake_exec
    out = asyncio.run(agent.call_tool(1, "c1", name, args, [{"id": "long_stare"}]))
    return out, executed


def test_demo_eye_rub_starts_palming_with_voice(tmp_path):
    app = FakeApp(tmp_path, {"approved": True})
    app.log_event = lambda *a, **k: None
    agent = Agent(app)
    started = {}

    async def fake_exercise(kind, duration_s, steps, call_id=None):
        started.update(kind=kind, duration_s=duration_s, first=steps[0]["text"], call_id=call_id)

    async def no_outcome(*_a, **_k):
        return None

    agent._exercise = fake_exercise
    agent.evaluate_outcome = no_outcome
    asyncio.run(agent.demo_palming([{"id": "eye_rub", "value": 1, "fired_at": 1}]))
    assert started["kind"] == "palming" and started["duration_s"] == 40
    assert "warm" in started["first"].lower()
    assert app.asked == [] and agent.busy is False
    assert any(m.get("type") == "agent_text" and "rubbing" in m["text"] for m in app.sent)


def test_first_use_always_asks_even_for_auto_tier(tmp_path):
    app = FakeApp(tmp_path, {"approved": True, "remember": True})
    out, ex = call(app, "remind_to_blink", {"count": 2, "intensity": 0.5})
    assert app.asked == ["remind_to_blink"] and ex == ["remind_to_blink"]
    assert app.db.approvals()["remind_to_blink"] == "approved"
    # second use of an auto-tier tool does not ask again
    app.asked.clear()
    call(app, "remind_to_blink", {"count": 2, "intensity": 0.5})
    assert app.asked == []


def test_decline_is_remembered_and_saves_preference(tmp_path):
    app = FakeApp(tmp_path, {"approved": False, "remember": True})
    out, ex = call(app, "set_dark_mode", {"enabled": True})
    assert ex == [] and "declined" in out
    assert app.db.approvals()["set_dark_mode"] == "declined"
    assert any(p["key"] == "decline:set_dark_mode" and p["source"] == "learned" for p in app.db.preferences())


def test_timeout_decline_not_remembered(tmp_path):
    app = FakeApp(tmp_path, None)
    out, ex = call(app, "set_dark_mode", {"enabled": True})
    assert ex == [] and "set_dark_mode" not in app.db.approvals()


def test_blocked_never_executes(tmp_path):
    app = FakeApp(tmp_path, {"approved": True})
    app.settings["tools.remind_to_blink.tier"] = "blocked"
    out, ex = call(app, "remind_to_blink", {"count": 2, "intensity": 0.5})
    assert ex == [] and app.asked == [] and out.startswith("blocked")


def test_suppressed_in_call_but_silent_tools_run(tmp_path):
    app = FakeApp(tmp_path, {"approved": True})
    app.active = {"name": "zoom.us", "bundle_id": "us.zoom.xos", "window_title": "Zoom Meeting", "category": "call"}
    out, ex = call(app, "remind_to_blink", {"count": 2, "intensity": 0.5})
    assert ex == [] and "blocked" in out
    out, ex = call(app, "set_dark_mode", {"enabled": True})
    assert ex == ["set_dark_mode"]


def test_invalid_args_fail(tmp_path):
    app = FakeApp(tmp_path, {"approved": True})
    out, ex = call(app, "remind_to_blink", {"count": 9, "intensity": 0.5})
    assert ex == [] and "error" in out
    out, ex = call(app, "nope", {})
    assert ex == [] and "error" in out


def test_doctor_gate_needs_eligibility(tmp_path):
    app = FakeApp(tmp_path, {"approved": True})
    out, ex = call(app, "suggest_seeing_eye_doctor", {"evidence": "x"})
    assert ex == [] and "not eligible" in out
    from eyeos import demo
    demo.seed(app.db)
    out, ex = call(app, "suggest_seeing_eye_doctor", {"evidence": "x"})
    assert ex == ["suggest_seeing_eye_doctor"]


def test_zen_blocks_every_visible_action(tmp_path):
    app = FakeApp(tmp_path, {"approved": True})
    app.zen.set_manual(True, 0)
    for name, args in (("remind_to_blink", {"count": 2, "intensity": 0.5}), ("set_dark_mode", {"enabled": True}),
                       ("ask_user", {"question": "ok?", "options": ["yes"]})):
        out, ex = call(app, name, args)
        assert ex == [] and app.asked == [] and "Zen" in out, name


def test_exercise_narration_reminds_during_long_steps_and_says_done(tmp_path, monkeypatch):
    import eyeos.agent as A
    app = FakeApp(tmp_path, None)
    spoken = []

    class Speaker:
        task = None
        last_react = 0.0

        def busy(self):
            return False

        async def speak(self, texts):
            spoken.extend(texts)
            self.task = asyncio.sleep(0)

        async def stop(self):
            pass
    app.speaker = Speaker()
    agent = Agent(app)
    monkeypatch.setattr(A, "REMIND_AFTER_S", 0.5)
    steps = [{"text": "Close your eyes.", "seconds": 1.8}, {"text": "Open slowly.", "seconds": 0.05}]
    asyncio.run(agent._narrate(steps, "palming"))
    assert spoken[0] == "Close your eyes."
    assert any(t.startswith("Keep your eyes closed") and "seconds to go" in t for t in spoken[1:-2])
    assert spoken[-2] == "Open slowly." and spoken[-1].startswith("The exercise is done")

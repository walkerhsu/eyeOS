import asyncio
import os

from eyeos.agent import Agent
from eyeos.db import DB


class FakeApp:
    def __init__(self, tmp_path, answer):
        self.db = DB(tmp_path / "t.db")
        self.settings = self.db.settings()
        self.active = {"name": "Safari", "bundle_id": "com.apple.Safari", "window_title": "x", "category": "reading"}
        self.answer = answer
        self.asked, self.sent, self.ui = [], [], []
        self.last_action = None

    async def send(self, m):
        self.sent.append(m)

    async def send_approvals(self):
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
    assert any("declined set_dark_mode" in p["rule"] for p in app.db.preferences())


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

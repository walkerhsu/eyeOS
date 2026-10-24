"""SQLite persistence (SPEC §10) and settings registry (SPEC §8).

All access happens on the asyncio thread, which makes it the single writer.
"""
import json
import sqlite3
import time
from pathlib import Path

DB_PATH = Path.home() / "Library/Application Support/eyeOS/eyeos.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings     (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS metrics_1hz  (ts REAL PRIMARY KEY, data TEXT NOT NULL, app_category TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS events       (id INTEGER PRIMARY KEY, ts REAL, kind TEXT, trigger_id TEXT, value REAL, details TEXT, run_id INTEGER, seeded INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS agent_runs   (id INTEGER PRIMARY KEY, ts_start REAL, ts_end REAL, status TEXT, triggers TEXT, context TEXT, images_sent INTEGER,
                                         thinking TEXT, text TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, error TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS tool_calls   (id INTEGER PRIMARY KEY, run_id INTEGER, ts REAL, name TEXT, args TEXT, status TEXT, tier TEXT, approval TEXT, result TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS outcomes     (id INTEGER PRIMARY KEY, call_id INTEGER, ts REAL, metric TEXT, before REAL, after REAL, verdict TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS approvals    (tool TEXT PRIMARY KEY, state TEXT, ts REAL);
CREATE TABLE IF NOT EXISTS preferences  (id INTEGER PRIMARY KEY, ts REAL, rule TEXT, app TEXT, source TEXT);
CREATE TABLE IF NOT EXISTS baselines    (id INTEGER PRIMARY KEY, ts REAL, data TEXT, reason TEXT);
CREATE TABLE IF NOT EXISTS calibration  (id INTEGER PRIMARY KEY, ts REAL, step INTEGER, data TEXT);
CREATE TABLE IF NOT EXISTS summaries    (date TEXT PRIMARY KEY, ts REAL, text TEXT, stats TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS conductor_log (ts REAL PRIMARY KEY, data TEXT);  -- text-only decisions of the on-device conductor
CREATE TABLE IF NOT EXISTS reflections  (id INTEGER PRIMARY KEY, ts REAL, period_start REAL, period_end REAL, reason TEXT, text TEXT, data TEXT);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_calls_run ON tool_calls(run_id);
"""

# Trigger defaults (§5): id -> (threshold, sustain_s, demo_threshold, demo_sustain_s)
TRIGGERS = {
    "low_blink_rate": (8, 120, 8, 30),
    "long_stare": (15, 0, 8, 0),
    "incomplete_blinks": (0.40, 60, 0.40, 20),
    "drowsy": (0.15, 0, 0.15, 0),
    "long_blinks": (3, 0, 3, 0),
    "sustained_squint": (0, 30, 0, 10),
    "too_close": (40, 20, 40, 10),
    "eye_rub": (0, 0, 0, 0),
    "yawning": (2, 0, 1, 0),
    "dark_room_bright_screen": (0, 60, 0, 15),
    "no_break": (1200, 0, 120, 0),
    "frequent_blinks": (25, 120, 22, 30),    # /min floor; fires above max(floor, 1.6 x baseline), not while talking
    "blink_decline": (0.2, 0, 0.15, 0),      # fraction the blink rate fell over ~12 min (16 -> 14 -> 12 -> 10)
    "posture_drift": (1, 60, 1, 15),         # posture issues vs the start of the session, sustained
    "break_taken": (0, 0, 0, 0),
    "heartbeat": (900, 0, 180, 0),
}


def _num(lo=None, hi=None, typ=(int, float)):
    def check(v):
        return isinstance(v, typ) and not isinstance(v, bool) and (lo is None or v >= lo) and (hi is None or v <= hi)
    return check


_bool = lambda v: isinstance(v, bool)
_str = lambda v: isinstance(v, str) and len(v) < 500
_tier = lambda v: v in ("auto", "ask", "blocked")

# key -> (default, validator)
SETTINGS = {
    "ui.show_camera_image": (True, _bool),
    "tracking.paused": (False, _bool),
    "agent.enabled": (True, _bool),
    "agent.model": ("claude-sonnet-5-5", lambda v: v in ("claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5")),
    "agent.provider": ("claude", lambda v: v in ("claude", "codex")),
    "agent.codex_model": ("", lambda v: isinstance(v, str) and len(v) < 64),  # "" = Codex's own default
    "agent.heartbeat_s": (900, _num(60, 3600, int)),
    "agent.global_gap_s": (120, _num(10, 1800, int)),
    "agent.trigger_cooldown_s": (600, _num(10, 3600, int)),
    "privacy.local_vision": (True, _bool),          # describe the screen with a local model; pixels never leave the Mac
    "privacy.local_model": ("gemma4", lambda v: isinstance(v, str) and 0 < len(v) < 80),
    "privacy.screen_interval_s": (30, _num(20, 600, int)),
    "agent.max_tool_iterations": (6, _num(1, 10, int)),
    "zen.enabled": (True, _bool),
    "zen.enter_min": (10, _num(1, 60)),
    "quiet_apps": ([], lambda v: isinstance(v, list) and all(_str(x) for x in v) and len(v) < 100),
    "calibration.distance_cm": (60, _num(20, 150)),
    "advanced.dip_start_o": (0.75, _num(0, 1.2)),
    "advanced.dip_end_o": (0.85, _num(0, 1.2)),
    "advanced.complete_o": (0.20, _num(0, 1)),
    "advanced.incomplete_max_o": (0.60, _num(0, 1)),
    "advanced.long_blink_s": (0.5, _num(0.1, 3)),
    "advanced.real_break_s": (20, _num(5, 300, int)),
    "audio.voice_id": ("", _str),  # empty = first voice from the Cartesia voices API
    "audio.speed": (1.0, _num(0.6, 1.5)),
    "demo.enabled": (False, _bool),
    "memory.suppressed": ([], lambda v: isinstance(v, list) and all(_str(x) for x in v)),  # learned keys the user deleted
    "memory.reset_at": (0, _num(0)),  # last "Reset memory": learning and reflection ignore evidence before it
}
for _id, (thr, sus, _, _) in TRIGGERS.items():
    SETTINGS[f"triggers.{_id}.enabled"] = (True, _bool)
    SETTINGS[f"triggers.{_id}.threshold"] = (thr, _num())
    SETTINGS[f"triggers.{_id}.sustain_s"] = (sus, _num(0, 3600))


def validate_setting(key, value, tool_names=()):
    if key.startswith("tools.") and key.endswith(".tier"):
        return key[6:-5] in tool_names and _tier(value)
    spec = SETTINGS.get(key)
    return spec is not None and spec[1](value)


class DB:
    def __init__(self, path=DB_PATH):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.c = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False)
        self.c.row_factory = sqlite3.Row
        self.c.execute("PRAGMA journal_mode=WAL")
        self.c.executescript(SCHEMA)
        try:  # learned memory rules are keyed so they can be updated in place (learning.py)
            self.c.execute("ALTER TABLE preferences ADD COLUMN key TEXT")
        except sqlite3.OperationalError:
            pass
        self.c.execute("DELETE FROM metrics_1hz WHERE ts < ?", (time.time() - 30 * 86400,))
        self.c.execute("DELETE FROM conductor_log WHERE ts < ?", (time.time() - 30 * 86400,))
        self.close_interrupted()

    def close_interrupted(self):
        """Runs, tool calls and calibration steps still in flight from a previous session (app quit mid-run,
        e.g. during an unanswered ask_user) can never finish; close them out so they don't show as pending forever."""
        msg = "interrupted: eyeOS quit before this finished"
        self.c.execute("UPDATE tool_calls SET status='failed', result=? "
                       "WHERE status IN ('requested', 'awaiting_approval', 'approved', 'executing')", (json.dumps(msg),))
        self.c.execute("UPDATE agent_runs SET status='error', error=?, ts_end=COALESCE(ts_end, ts_start) "
                       "WHERE status='started'", (msg,))
        # a calibration step's row has data NULL until it finishes (server.calibrate)
        reason = "eyeOS quit or restarted before this step finished."
        for r in self.q("SELECT ts, step FROM calibration WHERE data IS NULL"):
            self.c.execute("INSERT INTO events (ts, kind, details) VALUES (?, 'system', ?)",
                           (r["ts"], json.dumps({"event": "calibration_interrupted", "step": r["step"], "reason": reason})))
        self.c.execute("UPDATE calibration SET data=? WHERE data IS NULL", (json.dumps({"interrupted": reason}),))

    def q(self, sql, args=()):
        return [dict(r) for r in self.c.execute(sql, args).fetchall()]

    def x(self, sql, args=()):
        return self.c.execute(sql, args).lastrowid

    # settings
    def settings(self):
        s = {k: v[0] for k, v in SETTINGS.items()}
        for r in self.q("SELECT key, value FROM settings"):
            s[r["key"]] = json.loads(r["value"])
        return s

    def set_setting(self, key, value):
        self.x("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, json.dumps(value)))

    def reset_settings(self, prefix):
        self.x("DELETE FROM settings WHERE key LIKE ?", (prefix + "%",))

    # approvals
    def approvals(self):
        return {r["tool"]: r["state"] for r in self.q("SELECT tool, state FROM approvals")}

    def set_approval(self, tool, state):
        self.x("INSERT OR REPLACE INTO approvals VALUES (?, ?, ?)", (tool, state, time.time()))

    # baselines / calibration
    def baseline(self):
        r = self.q("SELECT data FROM baselines ORDER BY id DESC LIMIT 1")
        return json.loads(r[0]["data"]) if r else {}

    def save_baseline(self, data, reason):
        self.x("INSERT INTO baselines (ts, data, reason) VALUES (?, ?, ?)", (time.time(), json.dumps(data), reason))

    def preferences(self):
        return self.q("SELECT id, ts, rule, app, source, key FROM preferences ORDER BY id")

    def add_preference(self, rule, app=None, source="agent"):
        return self.x("INSERT INTO preferences (ts, rule, app, source) VALUES (?, ?, ?, ?)", (time.time(), rule, app, source))

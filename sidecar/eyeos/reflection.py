"""Reflection agent: looks back over a stretch of use and turns patterns into memory.

It runs when the display goes to sleep (the user stepped away for the night or for a while) and, on launch,
catches up on anything not yet reflected on (e.g. the Mac was shut down). It summarizes the period's numbers,
asks the reasoning agent for a short reflection plus 2-4 actionable rules, and stores those rules in memory
(source "reflection", replaced at each reflection). Only numbers and short labels go to the model.
"""
import json
import re
import time

MIN_GAP_S = 3 * 3600       # don't reflect more often than this
MIN_FACE_S = 30 * 60       # need at least this much time at the screen in the period
LOOKBACK_S = 7 * 86400     # first reflection looks back at most a week

SYSTEM = """You are eyeOS's reflection agent. eyeOS is an eye-comfort assistant on the user's Mac. You get numbers
from a stretch of the user's computer use: blink rate and eye score by hour and by situation, triggers that fired,
which nudges were used and whether they helped, what the user declined, Zen focus sessions, and the rules eyeOS
already follows. Find the 2-4 most useful patterns.

Reply with JSON only:
{"summary": "2-3 friendly sentences about this period, using the numbers",
 "rules": [{"rule": "an actionable rule for eyeOS's agent (when / what to do or avoid)", "evidence": "the numbers behind it"}],
 "try_next": "one small thing for the user to try"}
Rules must be grounded in the numbers, not repeat an existing rule, and never use medical labels or diagnose.
If there is too little data, say so and return an empty rules list."""


def last_period_end(db):
    r = db.q("SELECT MAX(period_end) e FROM reflections")
    return r[0]["e"] if r and r[0]["e"] else None


def start(db, now=None, reset_at=0):
    """Where the next reflection's period begins: after the last one, never before a memory reset."""
    return max(last_period_end(db) or (now or time.time()) - LOOKBACK_S, reset_at)


def due(db, now=None, reset_at=0):
    """(True, since) when there's enough unreflected use; else (False, reason)."""
    now = now or time.time()
    last = last_period_end(db)
    if last and now - last < MIN_GAP_S:
        return False, "reflected recently"
    since = start(db, now, reset_at)
    face_s = db.q("SELECT COUNT(*) n FROM metrics_1hz WHERE ts > ? AND seeded = 0", (since,))[0]["n"]
    if face_s < MIN_FACE_S:
        return False, f"only {face_s // 60} min at the screen since the last reflection"
    return True, since


def gather(db, since, until):
    rows = db.q("SELECT ts, data FROM metrics_1hz WHERE ts > ? AND ts <= ? AND seeded = 0 ORDER BY ts", (since, until))
    cond = db.q("SELECT ts, data FROM conductor_log WHERE ts > ? AND ts <= ? ORDER BY ts", (since, until))

    def bucket():
        return {"n": 0, "blink": [], "score": []}
    by_hour, by_sit = {}, {}
    ci, situation = 0, None
    for r in rows:
        d = json.loads(r["data"])
        while ci < len(cond) and cond[ci]["ts"] <= r["ts"]:
            situation = json.loads(cond[ci]["data"]).get("situation")
            ci += 1
        hour = time.strftime("%H:00", time.localtime(r["ts"]))
        for key, table in ((hour, by_hour), (situation or "unknown", by_sit)):
            b = table.setdefault(key, bucket())
            b["n"] += 1
            if d.get("blink_rate") is not None:
                b["blink"].append(d["blink_rate"])
            if d.get("eye_score") is not None:
                b["score"].append(d["eye_score"])

    def summarize(table):
        return {k: {"minutes": round(b["n"] / 60), "avg_blink_rate": round(sum(b["blink"]) / len(b["blink"]), 1) if b["blink"] else None,
                    "avg_eye_score": round(sum(b["score"]) / len(b["score"])) if b["score"] else None}
                for k, b in sorted(table.items()) if b["n"] >= 120}

    tools = {}
    for r in db.q("""SELECT c.name, c.status, c.approval, o.verdict, o.metric FROM tool_calls c LEFT JOIN outcomes o ON o.call_id = c.id
                     WHERE c.ts > ? AND c.ts <= ? AND c.seeded = 0""", (since, until)):
        t = tools.setdefault(r["name"], {"used": 0, "declined": 0, "verdicts": {}})
        t["used"] += r["status"] == "done"
        t["declined"] += r["approval"] == "declined"
        if r["verdict"] and not (r["name"] == "start_guided_eye_exercise" and r["metric"] == "since_real_break_s"):
            t["verdicts"][r["verdict"]] = t["verdicts"].get(r["verdict"], 0) + 1
    events = {r["k"]: r["n"] for r in db.q("""SELECT COALESCE(trigger_id, kind) k, COUNT(*) n FROM events
                                             WHERE ts > ? AND ts <= ? AND seeded = 0 AND kind IN ('trigger', 'break', 'rub', 'yawn')
                                             GROUP BY k""", (since, until))}
    zen = [json.loads(r["details"]) for r in db.q("SELECT details FROM events WHERE kind = 'zen' AND ts > ? AND ts <= ? AND seeded = 0",
                                                  (since, until))]
    zen_end = [z for z in zen if z.get("event") == "zen_end"]
    return {
        "period": {"from": time.strftime("%a %H:%M", time.localtime(since)), "to": time.strftime("%a %H:%M", time.localtime(until)),
                   "minutes_at_screen": round(len(rows) / 60)},
        "your_normal_blink_rate": (json.loads(db.q("SELECT data FROM baselines ORDER BY id DESC LIMIT 1")[0]["data"]).get("blink_rate")
                                   if db.q("SELECT 1 FROM baselines LIMIT 1") else None),
        "by_hour": summarize(by_hour), "by_situation": summarize(by_sit), "events": events, "nudges": tools,
        "zen": {"sessions": len(zen_end), "minutes": round(sum(z.get("duration_s", 0) for z in zen_end) / 60),
                "recap_highlights": [h["text"] for z in zen_end[-3:] for h in (z.get("recap") or {}).get("highlights", [])][:8]},
        "existing_rules": [p["rule"] for p in db.preferences()],
    }


def parse(text):
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        raise ValueError("reflection reply had no JSON")
    d = json.loads(m.group(0))
    rules = [r for r in d.get("rules") or [] if isinstance(r, dict) and r.get("rule")][:4]
    return {"summary": str(d.get("summary") or ""), "rules": rules, "try_next": d.get("try_next")}


def save(db, since, until, reason, result, stats):
    db.x("INSERT INTO reflections (ts, period_start, period_end, reason, text, data) VALUES (?, ?, ?, ?, ?, ?)",
         (time.time(), since, until, reason, result["summary"], json.dumps({**result, "stats": stats})))
    db.x("DELETE FROM preferences WHERE source = 'reflection'")
    for i, r in enumerate(result["rules"]):
        db.x("INSERT INTO preferences (ts, rule, app, source, key) VALUES (?, ?, NULL, 'reflection', ?)",
             (time.time(), r["rule"], f"reflect:{i}"))

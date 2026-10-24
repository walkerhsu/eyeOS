"""Demo-mode seeding (SPEC §12): 7 days of synthetic history, all rows seeded=1."""
import datetime as dt
import json
import random

TABLES = ("metrics_1hz", "events", "agent_runs", "tool_calls", "outcomes", "summaries")
CATS = (("coding", 0.9), ("reading", 1.25), ("other", 1.05))
TOOLS = [("remind_to_blink", "blink_rate", {"count": 3, "intensity": 0.5}),
         ("set_dark_mode", "squint_delta", {"enabled": True}),
         ("suggest_look_out_window", "since_real_break_s", {"message": "Look out the window for a moment?"}),
         ("start_guided_eye_exercise", "blink_rate", {"type": "palming", "duration_s": 40})]


def seed(db, days=7, rng=None):
    rng = rng or random.Random(7)
    wipe(db)
    today = dt.date.today()
    n = 0
    for d in range(days, 0, -1):
        day = today - dt.timedelta(days=d)
        k = (days - d) / max(1, days - 1)          # 0 -> 1 across the week
        base_br = 14 - 7 * k                         # 14 -> 7 blinks/min
        base_ip = 0.22 + 0.25 * k                    # rising incomplete %
        start = dt.datetime.combine(day, dt.time(9, 0)).timestamp()
        screen = 0
        rows = []
        for m in range(300):                         # 5 h at 1/min
            ts = start + m * 60 + (m // 60) * 900    # 15 min gap every hour
            cat, f = CATS[(m // 45) % 3]
            screen += 60
            rows.append((ts, json.dumps({
                "ts": ts, "face_present": True,
                "blink_rate": round(max(3, rng.gauss(base_br * f, 1.5)), 1),
                "incomplete_pct": round(min(0.9, max(0, rng.gauss(base_ip, 0.05))), 2),
                "perclos": round(max(0, rng.gauss(0.04 + 0.04 * k, 0.015)), 3),
                "distance_cm": round(rng.gauss(55 - 8 * k, 3), 1),
                "squint_delta": round(rng.gauss(0.05 + 0.08 * k, 0.03), 3),
                "longest_stare_s": round(rng.uniform(8, 18 + 10 * k), 1),
                "screen_time_today_s": screen, "app_category": cat}), cat, 1))
        db.c.executemany("INSERT OR IGNORE INTO metrics_1hz (ts, data, app_category, seeded) VALUES (?, ?, ?, ?)", rows)
        n += len(rows)
        for h in range(5):
            db.x("INSERT INTO events (ts, kind, value, details, seeded) VALUES (?, 'break', 25, ?, 1)",
                 (start + h * 4500 + 3700, json.dumps({"event": "break"})))
        for i in range(2 + round(5 * k)):            # >= 5 rubs/day late in the week
            db.x("INSERT INTO events (ts, kind, details, seeded) VALUES (?, 'rub', ?, 1)",
                 (start + rng.uniform(0, 18000), json.dumps({"event": "rub"})))
        for i in range(4):
            ts = start + 1800 + i * 4000
            tool, metric, args = TOOLS[i % len(TOOLS)]
            trig = "low_blink_rate" if metric == "blink_rate" else "no_break" if "look" in tool else "sustained_squint"
            eid = db.x("INSERT INTO events (ts, kind, trigger_id, value, details, seeded) VALUES (?, 'trigger', ?, ?, '{}', 1)",
                       (ts, trig, round(base_br, 1)))
            rid = db.x("""INSERT INTO agent_runs (ts_start, ts_end, status, triggers, images_sent, thinking, text, model,
                                                  input_tokens, output_tokens, seeded)
                          VALUES (?, ?, 'finished', ?, 2, ?, ?, 'claude-sonnet-5-5', 3100, 240, 1)""",
                       (ts + 1, ts + 4.2, json.dumps([{"id": trig, "value": round(base_br, 1), "fired_at": ts}]),
                        "Blink rate has been low for a while during coding.",
                        f"Blink rate is {base_br:.0f}/min, below the user's baseline. A gentle {tool.replace('_', ' ')} first."))
            db.x("UPDATE events SET run_id=? WHERE id=?", (rid, eid))
            cid = db.x("""INSERT INTO tool_calls (run_id, ts, name, args, status, tier, approval, result, seeded)
                          VALUES (?, ?, ?, ?, 'done', 'auto', 'approved', '"ok"', 1)""", (rid, ts + 3, tool, json.dumps(args)))
            if metric == "since_real_break_s":
                v, before, after = rng.choice(["confirmed_break", "confirmed_break", "no_break"]), None, None
            else:
                before = base_br * 0.8 if metric == "blink_rate" else 0.2
                good = rng.random() < (0.7 if tool == "remind_to_blink" else 0.45)
                after = before * (1.3 if good else 1.0) if metric == "blink_rate" else before * (0.7 if good else 1.0)
                v = "improved" if good else "neutral"
            db.x("INSERT INTO outcomes (call_id, ts, metric, before, after, verdict, seeded) VALUES (?, ?, ?, ?, ?, ?, 1)",
                 (cid, ts + 198, metric, before, after, v))
        db.x("INSERT OR REPLACE INTO summaries (date, ts, text, stats, seeded) VALUES (?, ?, ?, '{}', 1)",
             (day.isoformat(), start + 20000,
              f"You averaged {base_br * 0.9:.0f} blinks/min while coding and {base_br * 1.25:.0f} while reading. "
              f"You took 5 real breaks. The blink pulse helped most when your rate dipped."))
    return n


def wipe(db):
    for t in TABLES:
        db.x(f"DELETE FROM {t} WHERE seeded=1")

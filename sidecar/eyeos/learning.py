"""Turns what happened into memory: what works for this user, what they decline, what rarely helps.

Before this, memory only grew when the user declined a tool on first use or the LLM chose to call
save_user_preference (it never did in 69 runs). These rules are derived deterministically from outcomes,
approvals and ask_user answers, kept up to date (counts refresh, unsupported rules disappear) and shown to the
agent with every run. Learned rows carry a `key`; a key the user deleted is never re-learned.
"""
import json
import time

WINDOW_S = 14 * 86400
HELPED = {"improved", "confirmed_break"}
NEGATIVE = ("not now", "no", "later", "skip", "stop", "don't", "dont", "maybe later")
MIN_EVIDENCE = 3

PHRASE = {
    "remind_to_blink": "The edge-glow blink reminder", "suggest_look_out_window": "The 20-20-20 break card",
    "start_guided_eye_exercise": "Guided eye exercises", "play_ambient_cue": "Soft sound cues",
    "set_dark_mode": "Switching dark mode", "set_increase_contrast": "Increasing contrast",
    "set_display_brightness": "Adjusting brightness", "set_text_zoom": "Enlarging text",
    "suggest_posture_reset": "The posture card", "switch_to_audio": "Reading pages aloud",
    "summarize_aloud": "Spoken summaries", "set_focus_mode": "Turning on Focus", "enlarge_active_window": "Enlarging the window",
}


def _phrase(tool):
    return PHRASE.get(tool, tool.replace("_", " ").capitalize())


def derive(db, now=None, suppressed=(), reset_at=0):
    """key -> rule text, from the last 14 days (or since the user last reset memory, if later)."""
    now = now or time.time()
    since = max(now - WINDOW_S, reset_at)
    rules = {}

    # 1. what helps / what rarely helps (outcome verdicts, measured by the camera before vs after)
    stats = {}
    for r in db.q("""SELECT c.name, o.verdict FROM outcomes o JOIN tool_calls c ON c.id = o.call_id
                     WHERE o.ts > ? AND o.seeded = 0 AND o.verdict != 'inconclusive'
                     AND NOT (c.name = 'start_guided_eye_exercise' AND o.metric = 'since_real_break_s')""", (since,)):
        # (exercises used to be scored by "did you look away", which palming never is; those verdicts are ignored)
        n, h = stats.get(r["name"], (0, 0))
        stats[r["name"]] = (n + 1, h + (r["verdict"] in HELPED))
    for tool, (n, h) in stats.items():
        if n < MIN_EVIDENCE:
            continue
        if h / n >= 0.6:
            rules[f"effect:{tool}"] = f"{_phrase(tool)} tends to help this user ({h} of {n} times recently): a good first choice."
        elif h / n <= 0.25:
            rules[f"effect:{tool}"] = (f"{_phrase(tool)} rarely helps this user ({h} of {n} times recently): "
                                       "prefer a different action.")

    # 2. what the user turns down
    declined = {r["name"]: r["n"] for r in db.q(
        "SELECT name, COUNT(*) n FROM tool_calls WHERE approval = 'declined' AND ts > ? AND seeded = 0 GROUP BY name", (since,))}
    for r in db.q("SELECT tool FROM approvals WHERE state = 'declined' AND ts > ?", (reset_at,)):
        declined[r["tool"]] = max(declined.get(r["tool"], 0), 2)  # a remembered first-use "no" counts as a clear dislike
    for tool, n in declined.items():
        if n >= 2:
            rules[f"decline:{tool}"] = f"User has declined {_phrase(tool).lower()} ({n} times): don't use it unless they ask."
    timeouts = db.q("SELECT COUNT(*) n FROM tool_calls WHERE approval = 'timeout' AND ts > ? AND seeded = 0", (since,))[0]["n"]
    if timeouts >= MIN_EVIDENCE:
        rules["approval:ignored"] = (f"User often leaves approval prompts unanswered ({timeouts} times): "
                                     "prefer tools that are already approved.")

    # 3. how the user answers questions
    answers = []
    for r in db.q("SELECT result FROM tool_calls WHERE name = 'ask_user' AND status = 'done' AND ts > ? AND seeded = 0", (since,)):
        try:
            choice = (json.loads(r["result"] or "{}") or {}).get("choice")
        except (ValueError, AttributeError):
            choice = None
        if choice:
            answers.append(choice.lower())
    neg = sum(1 for a in answers if any(a.startswith(w) for w in NEGATIVE))
    if len(answers) >= MIN_EVIDENCE - 1 and neg >= 2 and neg / len(answers) >= 0.5:
        rules["ask:negative"] = (f"User often says no or not now when asked ({neg} of {len(answers)}): "
                                 "ask less and prefer silent nudges.")
    elif len(answers) >= MIN_EVIDENCE and (len(answers) - neg) / len(answers) >= 0.7:
        rules["ask:positive"] = (f"User usually accepts when asked ({len(answers) - neg} of {len(answers)}): "
                                 "offering a break or exercise works.")
    return {k: v for k, v in rules.items() if k not in suppressed}


def apply(db, rules):
    """Upsert learned rules, drop ones no longer supported. Returns the keys that are new."""
    current = {r["key"]: r for r in db.q("SELECT id, key, rule FROM preferences WHERE source = 'learned' AND key IS NOT NULL")}
    new = []
    for key, rule in rules.items():
        if key not in current:
            db.x("INSERT INTO preferences (ts, rule, app, source, key) VALUES (?, ?, NULL, 'learned', ?)", (time.time(), rule, key))
            new.append(key)
        elif current[key]["rule"] != rule:
            db.x("UPDATE preferences SET rule = ?, ts = ? WHERE id = ?", (rule, time.time(), current[key]["id"]))
    for key, row in current.items():
        if key not in rules:
            db.x("DELETE FROM preferences WHERE id = ?", (row["id"],))
    return new

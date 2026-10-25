"""Habit coach: quiet, instant fixes for unconscious eye habits (habit reversal: notice it, swap it, fix the cause,
show progress). Pure state; the server wires it to camera events, the UI and the agent.

- Hands at the eyes: fingertips at an eye while the eyes close get a soft cue within ~0.15 s, before a rub gets
  going; a rub or a lash pull then gets an offer to swap it for palming. Hair, a hand on the head, a chin in hand or
  pushing up glasses leave the eyes open, so they never count.
- Leaning in: the lens darkens the screen edges while you sit too close and clears when you sit back.
- Squinting at small text: one tap makes the text bigger; after two yeses in an app it just does it.
- Triggers: what tends to come before a habit (no break for 45 min, low blinking, late evening...), so the agent
  can act before the urge.
"""
from .blur import ramp

SWAP_OPTION = "Palm 20 s"
SWAP_TEXT = {"rub": "Itchy eyes? Swap the rub for 20 s of palming: same relief, no pressure.",
             "lash_pull": "Hands at your lashes? Try 20 s of palming instead."}
OFFER_GAP_S, DEMO_OFFER_GAP_S, MAX_DECLINES = 300, 45, 3

LEAN = {"close": 0.8, "clear": 0.88,   # x calibrated distance: closer = leaning in; farther = sat back (hysteresis)
        "start_s": 30, "full_s": 45, "demo_start_s": 8, "demo_full_s": 15, "hold_s": 60}

ZOOM_OPTION = "Bigger"
ZOOM = {"squint_s": 5, "gap_s": 600, "auto_after": 2, "apps": ("coding", "reading", "writing")}  # where Cmd+ zooms text

# condition key, how it reads in a rule, what to do about it, SQL over metrics_1hz (? = baseline blink rate),
# and the same test on the context saved with a habit event
CONDITIONS = [
    ("no_break", "after 45+ min without a real break", "suggest a break before then",
     "json_extract(data, '$.since_real_break_s') >= 2700", lambda c, b: (c.get("since_real_break_s") or 0) >= 2700),
    ("low_blink", "when blinking drops well below normal", "start blink cues early",
     "json_extract(data, '$.blink_rate') < 0.7 * ?",
     lambda c, b: c.get("blink_rate") is not None and c["blink_rate"] < 0.7 * b),
    ("long_stare", "after long stares without blinking", "a blink cue or blink blur first",
     "json_extract(data, '$.longest_stare_s') >= 15", lambda c, b: (c.get("longest_stare_s") or 0) >= 15),
    ("squint", "while squinting", "make text bigger or fix the brightness",
     "json_extract(data, '$.squinting') = 1", lambda c, b: bool(c.get("squinting"))),
    ("dark_room", "in a dark room with a bright screen", "dim the screen or use dark mode",
     "json_extract(data, '$.room_luma') < 60 AND json_extract(data, '$.screen_luma') > 170",
     lambda c, b: (c.get("room_luma") or 999) < 60 and (c.get("screen_luma") or 0) > 170),
    ("long_session", "late in long sessions (90+ min)", "suggest a real break",
     "json_extract(data, '$.session_s') >= 5400", lambda c, b: (c.get("session_s") or 0) >= 5400),
    ("evening", "in the evening", "lower the brightness and suggest rest",
     "CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) >= 18", lambda c, b: (c.get("hour") or 0) >= 18),
]


class HabitCoach:
    """When to cue a touch at the eyes, and when to offer swapping a rub or lash pull for palming."""

    def __init__(self):
        self.last_offer = -1e9
        self.declines = {}  # day -> "Not now" count

    def on_touch(self, allowed):
        """Cue this touch? Not when silenced (Zen, calls, meetings, exercises)."""
        return allowed

    def on_habit(self, t, allowed, demo, day):
        """A rub or lash pull happened: offer the swap? At most one offer per few minutes, none after 3 noes a day."""
        gap = DEMO_OFFER_GAP_S if demo else OFFER_GAP_S
        offer = allowed and t - self.last_offer >= gap and self.declines.get(day, 0) < MAX_DECLINES
        if offer:
            self.last_offer = t
        return offer

    def answered(self, choice, day):
        if choice == "Not now":  # an ignored offer isn't a no
            self.declines[day] = self.declines.get(day, 0) + 1


class LeanLens:
    """0-1 strength of the edge vignette: on after leaning in for a while, off once you sit back."""

    def __init__(self):
        self.close_since = None
        self.hold_until = 0.0

    def update(self, t, distance, cal_distance, stale, allowed, demo=False):
        if not allowed or not distance or not cal_distance:
            self.close_since = None
            return 0.0
        if stale:  # head turned: the distance can't be trusted right now
            return 0.0
        if distance < LEAN["close"] * cal_distance:
            self.close_since = self.close_since or t
        elif distance > LEAN["clear"] * cal_distance:
            self.close_since = None
        if self.close_since is None or t < self.hold_until:
            return 0.0
        start, full = (LEAN["demo_start_s"], LEAN["demo_full_s"]) if demo else (LEAN["start_s"], LEAN["full_s"])
        return round(ramp(t - self.close_since, start, full), 3)

    def close_for(self, t):
        return t - self.close_since if self.close_since else 0.0

    def hold(self, t):
        """Give a better fix (bigger text) a chance before nudging to sit back."""
        self.hold_until = t + LEAN["hold_s"]


class ZoomCoach:
    """Offer bigger text when squinting (or leaning in at small text) in an app where Cmd+ zooms."""

    def __init__(self):
        self.last = {}  # bundle id -> last offer

    def want(self, t, bundle_id, category, squint_s, lean_small, allowed):
        if not allowed or not bundle_id or category not in ZOOM["apps"]:
            return False
        if (squint_s or 0) < ZOOM["squint_s"] and not lean_small:
            return False
        if t - self.last.get(bundle_id, -1e9) < ZOOM["gap_s"]:
            return False
        self.last[bundle_id] = t
        return True


def habit_triggers(contexts, base, baseline):
    """What tends to come before a habit: conditions that held for at least 3 events and half of them, and are at
    least 1.5x more common then than overall. `base` = share of all screen time per condition. Top 2 by lift."""
    n, found = len(contexts), []
    if n < 3:
        return found
    for key, label, advice, _, test in CONDITIONS:
        if key == "low_blink" and not baseline or base.get(key) is None:
            continue
        k = sum(1 for c in contexts if test(c, baseline))
        lift = (k / n) / max(base[key], 0.01)
        if k >= 3 and k / n >= 0.5 and lift >= 1.5:
            found.append({"key": key, "label": label, "advice": advice, "k": k, "n": n, "lift": round(lift, 1)})
    return sorted(found, key=lambda f: -f["lift"])[:2]

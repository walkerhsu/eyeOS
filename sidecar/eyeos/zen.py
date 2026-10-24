"""Zen mode: detect sustained deep focus and keep eyeOS invisible while it lasts.

Metrics keep recording; the agent, overlays and sounds stay silent. When Zen ends, the server shows
one recap card. Pure logic (no I/O) so it can be unit-tested with synthetic samples.
"""
import collections
import statistics

WORK = {"coding", "design", "writing", "reading"}
IDLE_INPUT_S = 60       # input older than this counts as "not working" for that second
EXIT_IDLE_S = 180       # no keyboard/mouse for this long ends auto Zen
EXIT_AWAY_S = 60        # face absent this long ends auto Zen
EXIT_OFFTASK_S = 60     # a non-work app in front this long ends auto Zen


class Zen:
    def __init__(self):
        self.samples = collections.deque(maxlen=3600)  # 1 Hz: (ts, face, on_screen, input_age, category)
        self.active = False
        self.since = None
        self.source = None          # "auto" | "manual"
        self.manual_off = False     # user ended Zen: don't auto-enter again until the next break
        self.held_back = 0          # triggers silenced during the current Zen
        self.blinks = []            # blink_rate samples during the current Zen
        self.longest_stare = 0.0
        self.offtask_since = None

    def state(self, now):
        return {"active": self.active, "since": self.since, "source": self.source, "held_back": self.held_back,
                "duration_s": round(now - self.since) if self.active and self.since else 0}

    def set_manual(self, on, now):
        """Returns ("enter"|"exit", info) or None."""
        if on and not self.active:
            self.manual_off = False
            return "enter", self._enter(now, "manual")
        if not on and self.active:
            self.manual_off = True
            return "exit", self._exit(now, "manual")
        return None

    def tick(self, now, snap, input_age, category, enter_s, enabled=True):
        """Feed one 1 Hz sample. Returns ("enter"|"exit", info) on a state change, else None."""
        face = bool(snap.get("face_present"))
        self.samples.append((now, face, bool(snap.get("gaze_on_screen")), input_age, category))
        if self.active:
            if snap.get("blink_rate") is not None and face:
                self.blinks.append(snap["blink_rate"])
            self.longest_stare = max(self.longest_stare, snap.get("current_stare_s") or 0)
            reason = self._exit_reason(now, snap, input_age, category)
            if reason:
                return "exit", self._exit(now, reason)
            return None
        if self.manual_off and (snap.get("since_real_break_s") or 0) < 30:
            self.manual_off = False  # a real break re-arms auto detection
        if enabled and not self.manual_off and self._should_enter(now, snap, enter_s):
            return "enter", self._enter(now, "auto")
        return None

    def _should_enter(self, now, snap, enter_s):
        win = [s for s in self.samples if now - s[0] <= enter_s]
        if not win or now - win[0][0] < enter_s * 0.95:
            return False  # not enough history yet
        if (snap.get("since_real_break_s") or 0) < enter_s:
            return False  # looked away for a real break inside the window
        n = len(win)
        faces = [s for s in win if s[1]]
        if len(faces) < 0.85 * n:
            return False
        if sum(1 for s in faces if s[2]) < 0.75 * len(faces):
            return False
        if sum(1 for s in win if s[3] is not None and s[3] < IDLE_INPUT_S) < 0.7 * n:
            return False
        if any(s[4] == "call" for s in win):
            return False
        return sum(1 for s in win if s[4] in WORK) >= 0.8 * n

    def _exit_reason(self, now, snap, input_age, category):
        if category == "call":
            return "call"
        if self.source == "manual":
            return None  # manual Zen lasts until the user ends it
        if (snap.get("since_real_break_s") or 0) < 5 and now - self.since > 30:
            return "break"
        recent = [s for s in self.samples if now - s[0] <= EXIT_AWAY_S]
        if recent and now - recent[0][0] >= EXIT_AWAY_S * 0.9 and not any(s[1] for s in recent):
            return "away"
        if input_age is not None and input_age > EXIT_IDLE_S:
            return "idle"
        if category in WORK:
            self.offtask_since = None
        else:
            self.offtask_since = self.offtask_since or now
            if now - self.offtask_since >= EXIT_OFFTASK_S:
                return "switched"
        return None

    def _enter(self, now, source):
        self.active, self.since, self.source = True, now, source
        self.held_back, self.blinks, self.longest_stare, self.offtask_since = 0, [], 0.0, None
        return {"since": now, "source": source}

    def _exit(self, now, reason):
        info = {"since": self.since, "duration_s": round(now - self.since), "reason": reason, "source": self.source,
                "held_back": self.held_back, "longest_stare_s": round(self.longest_stare, 1),
                "blink_rate": round(statistics.fmean(self.blinks), 1) if self.blinks else None}
        self.active, self.since, self.source = False, None, None
        return info


def blink_base(cal):
    """Your calibrated blink rate, clamped to a plausible resting range so a bad calibration can't skew everything."""
    return min(25.0, max(10.0, cal.get("blink_rate") or 15.0))


def blink_low(base, floor=8):
    return max(floor, 0.6 * base)


def blink_high(base, floor=25):
    return max(floor, 1.6 * base)


def eye_score(m, cal):
    """0-100 composite of the live strain signals (100 = relaxed eyes). None without a face or calibration."""
    if not m.get("face_present") or not m.get("calibrated"):
        return None

    def ramp(v, lo, hi, pts):  # 0 pts at lo, full pts at hi
        if v is None:
            return 0.0
        return pts * min(1.0, max(0.0, (v - lo) / (hi - lo)))
    base = blink_base(cal)
    pen = 0.0
    if m.get("blink_rate") is not None:  # a band around your normal: too few dries the eye, too many signals irritation
        pen += 30 * min(1.0, max(0.0, 1 - m["blink_rate"] / base))
        pen += ramp(m["blink_rate"], blink_high(base), blink_high(base) + 10, 15)
    if (m.get("blink_trend") or {}).get("declining"):
        pen += 10  # blinking has been sliding for ~10 min: a fatigue sign
    pen += ramp(m.get("incomplete_pct"), 0.2, 0.6, 15)
    pen += ramp(m.get("current_stare_s"), 10, 30, 10)
    pen += ramp(m.get("perclos"), 0.08, 0.2, 15)
    if m.get("distance_cm") is not None and not m.get("distance_stale"):
        pen += ramp(-m["distance_cm"], -50, -35, 10)
    pen += ramp(m.get("since_real_break_s"), 1200, 3600, 10)
    pen += 10 if m.get("squinting") else 0
    return round(max(0.0, 100 - pen))

"""Camera-checked eye exercises: counts full and half blinks, catches peeking during palming, and scores how well the
eyes follow the gaze_trace dot. Pure state fed with events and 5 Hz snapshots; the caller speaks the reactions."""
import math
import statistics
from collections import deque

PERIOD_S = 6.0      # one lap of the gaze_trace figure-8 (the Swift dot uses the same formula)
WINDOW_S = 4.0      # gaze accuracy is the correlation over this window
TARGET_BLINKS = 10
OPEN_O = 0.5        # openness above this counts as eyes open
OPEN_O_HANDS = 0.75  # with hands at the face, only clearly wide-open eyes count (a covered eye can read as half open)
PEEK_S = 1.5        # eyes open this long during palming = peeking
BLINK_S = 0.6       # a closure shorter than this is a blink: the eyes are still open
SETTLE_S = 4.0      # time to close the eyes / find the dot once the checked part starts

COUNTS = ["One.", "Two.", "Three.", "Four.", "Five. Halfway there.", "Six.", "Seven.", "Eight.", "Nine.",
          "Ten. Perfect. Keep going at your own pace."]
PHRASES = {"half": "That one was only half. Close all the way.",
           "peek": "I can see you peeking. Close your eyes again.",
           "head": "Eyes only. Keep your head still.",
           "on_it": "Nice, you're right on it.",
           "catch_up": "Catch up with the dot."}
COOLDOWN_S = {"half": 6, "peek": 6, "head": 8, "on_it": 30, "catch_up": 8}
CHECKED = {"deliberate_blink": {0, 1, 2, 3}, "palming": {1, 2}, "gaze_trace": {1, 2}}  # step indices the camera checks


def dot(t):
    """The gaze_trace dot at t seconds, in -1..1 screen units: a wide horizontal figure-8 (webcam gaze is
    reliable left-right, weak up-down)."""
    return math.sin(2 * math.pi * t / PERIOD_S), 0.35 * math.sin(4 * math.pi * t / PERIOD_S)


def corr(xs, ys):
    """Pearson correlation; 0 when either side is flat."""
    if len(xs) < 3:
        return 0.0
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    return sxy / math.sqrt(sxx * syy) if sxx > 1e-12 and syy > 1e-12 else 0.0


class Gym:
    def __init__(self, kind, steps, t0):
        self.kind, self.t0 = kind, t0
        self.ends, acc = [], 0.0
        for s in steps:
            acc += s["seconds"]
            self.ends.append(acc)
        checked = sorted(CHECKED.get(kind, ()))
        self.check_from = (self.ends[checked[0] - 1] if checked and checked[0] > 0 else 0.0) + (SETTLE_S if checked else 0)
        self.checked = set(checked)
        self.said = {}            # phrase key -> last time spoken
        self.full = self.half = 0
        self.closed_s = self.open_s = 0.0
        self.open_since = None
        self.shut_since = None
        self.shut_pending = 0.0   # time shut so far, until we know whether it was a blink or a real closure
        self.peeking = False
        self.samples = deque()    # (t, gx, yaw, dot_x)
        self.accuracy = None
        self.acc_hist = []
        self.low_since = None
        self.last_t = None

    def phrases(self):
        """Everything this exercise might say live, so the voice can be synthesized before it's needed."""
        keys = {"deliberate_blink": ("half",), "palming": ("peek",), "gaze_trace": ("head", "on_it", "catch_up")}
        return [PHRASES[k] for k in keys.get(self.kind, ())] + (COUNTS if self.kind == "deliberate_blink" else [])

    def step(self, t):
        e = t - self.t0
        return next((i for i, end in enumerate(self.ends) if e < end), len(self.ends))

    def checking(self, t):
        return self.step(t) in self.checked and t - self.t0 >= self.check_from

    def _react(self, key, t):
        if t - self.said.get(key, -1e9) < COOLDOWN_S[key]:
            return None
        self.said[key] = t
        return PHRASES[key]

    def feed_events(self, events, t):
        """Blink events from the camera; returns a reaction to speak, if any."""
        if self.kind != "deliberate_blink" or self.step(t) not in self.checked:
            return None
        say = None
        for e in events:
            if e["kind"] in ("blink", "eyes_closed"):  # a slow squeeze can outlast a blink and end as eyes_closed
                self.full += 1
                if self.full <= TARGET_BLINKS:
                    say = COUNTS[self.full - 1]
            elif e["kind"] == "incomplete":
                self.half += 1
                say = self._react("half", t) or say
        return say

    def tick(self, t, snap):
        """One 5 Hz snapshot; returns a reaction to speak, if any."""
        dt = 0.0 if self.last_t is None else min(t - self.last_t, 0.5)
        self.last_t = t
        if not self.checking(t):
            self.open_since = self.shut_since = None
            self.shut_pending, self.peeking = 0.0, False
            return None
        if self.kind == "palming":
            return self._palming(t, dt, snap)
        if self.kind == "gaze_trace":
            return self._gaze(t, snap)
        return None

    def _palming(self, t, dt, snap):
        # no face (palms over it) counts as covered; eyes the camera can see open count as open, hands or not
        o = snap.get("o")
        is_open = (bool(snap.get("face_present")) and o is not None
                   and o > (OPEN_O_HANDS if snap.get("rubbing") else OPEN_O))
        if is_open:
            self.open_s += dt + self.shut_pending  # a closure shorter than a blink was just a blink
            self.shut_since, self.shut_pending = None, 0.0
            self.open_since = self.open_since or t
        else:
            self.shut_since = self.shut_since or t
            if t - self.shut_since < BLINK_S:
                self.shut_pending += dt
            else:  # a real closure: count it all as closed, and peeking starts over
                self.closed_s += dt + self.shut_pending
                self.shut_pending, self.open_since = 0.0, None
        self.peeking = self.open_since is not None and t - self.open_since >= PEEK_S
        return self._react("peek", t) if self.peeking else None

    def _gaze(self, t, snap):
        o, gx = snap.get("o"), snap.get("gx")
        if snap.get("face_present") and gx is not None and (o is None or o > OPEN_O):  # skip blinks: gaze is junk then
            self.samples.append((t, gx, snap.get("yaw_deg"), dot(t - self.t0)[0]))
        while self.samples and self.samples[0][0] < t - WINDOW_S:
            self.samples.popleft()
        if len(self.samples) < 12:
            return None
        xs = [s[3] for s in self.samples]
        # the camera image isn't mirrored, so the sign depends on setup: only how tightly gaze follows matters
        r = abs(corr([s[1] for s in self.samples], xs))
        yaw = [(s[2], s[3]) for s in self.samples if s[2] is not None]
        ry = abs(corr([y for y, _ in yaw], [x for _, x in yaw])) if len(yaw) >= 12 else 0.0
        self.accuracy = round(100 * min(1.0, max(0.0, (r - 0.2) / 0.6)))
        self.acc_hist.append(self.accuracy)
        self.low_since = (self.low_since or t) if self.accuracy < 30 else None
        if ry > 0.6 and ry > r:
            return self._react("head", t)
        if self.accuracy >= 70:
            return self._react("on_it", t)
        if self.low_since and t - self.low_since >= 3:
            return self._react("catch_up", t)
        return None

    def score(self):
        if self.kind == "deliberate_blink":
            n = self.full + self.half
            return round(100 * self.full / n) if n else None
        if self.kind == "palming":
            n = self.closed_s + self.open_s
            return round(100 * self.closed_s / n) if n > 1 else None
        if self.kind == "gaze_trace":
            return round(statistics.fmean(self.acc_hist)) if self.acc_hist else None
        return None

    def summary(self):
        s = self.score()
        if self.kind == "deliberate_blink":
            return f"{self.full} full blink{'' if self.full == 1 else 's'}" + (f" · {self.half} half" if self.half else "")
        if self.kind == "palming" and s is not None:
            return f"Eyes closed {s}% of the time"
        if self.kind == "gaze_trace" and s is not None:
            return f"Tracking accuracy {s}%"
        return "Nice work."

    def progress(self, t):
        return {"kind": self.kind, "checking": self.checking(t), "full": self.full, "half": self.half,
                "target": TARGET_BLINKS, "closed_pct": self.score() if self.kind == "palming" else None,
                "peeking": self.peeking, "accuracy": self.accuracy, "summary": self.summary()}

    def result(self):
        r = {"score": self.score(), "summary": self.summary()}
        if self.kind == "deliberate_blink":
            r.update(full=self.full, half=self.half)
        return r

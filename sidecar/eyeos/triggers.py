"""Deterministic trigger engine + rate-limited queue (SPEC §5)."""
from .db import TRIGGERS
from .zen import blink_base, blink_high, blink_low

GRACE_S = 3.0          # a sustained condition survives dropouts this short (one noisy frame used to reset it)
PRIORITY = {"eye_rub", "too_close"}  # skip the global gap and the conductor's "not now": act while it's happening
STALE_S = 600          # a nudge held this long (e.g. through a meeting) is no longer relevant


class Triggers:
    def __init__(self):
        self.since = {}       # id -> ts the condition became true
        self.false_at = {}    # id -> ts the condition last went false (for the grace period)
        self.last_fired = {}  # id -> ts
        self.pending = {}     # id -> trigger dict, merged into the next run
        self.last_run = -1e9
        self.last_event_run = -1e9

    def params(self, tid, s):
        thr, sus, dthr, dsus = TRIGGERS[tid]
        if s["demo.enabled"]:
            return dthr, dsus
        return s[f"triggers.{tid}.threshold"], s[f"triggers.{tid}.sustain_s"]

    def evaluate(self, snap, events, s, now, active=True):
        """Returns the triggers fired at this tick (already queued in self.pending)."""
        fired = []
        if not active:
            self.since.clear()
            return fired
        cooldown = 45 if s["demo.enabled"] else s["agent.trigger_cooldown_s"]
        kinds = {e["kind"] for e in events}
        for tid in TRIGGERS:
            if not s[f"triggers.{tid}.enabled"]:
                continue
            thr, sus = self.params(tid, s)
            if tid == "heartbeat":
                thr = 180 if s["demo.enabled"] else s["agent.heartbeat_s"]
            cond, value = self._cond(tid, snap, kinds, thr, now)
            if not cond:
                self.false_at.setdefault(tid, now)
                if now - self.false_at[tid] > GRACE_S:
                    self.since.pop(tid, None)
                continue
            self.false_at.pop(tid, None)
            start = self.since.setdefault(tid, now)
            if now - start < sus:
                continue
            if now - self.last_fired.get(tid, -1e9) < (thr if tid == "heartbeat" else cooldown):
                continue
            self.last_fired[tid] = now
            t = {"id": tid, "value": value, "fired_at": now}
            self.pending[tid] = t
            fired.append(t)
        return fired

    def _cond(self, tid, m, kinds, thr, now):
        g = m.get
        base = blink_base({"blink_rate": g("baseline_blink_rate")})
        if tid == "low_blink_rate":  # relative to your normal; blink_rate is None while talking or on a call
            return g("blink_rate") is not None and m["blink_rate"] < blink_low(base, thr), g("blink_rate")
        if tid == "frequent_blinks":
            return g("blink_rate") is not None and m["blink_rate"] > blink_high(base, thr), g("blink_rate")
        if tid == "blink_decline":
            tr = g("blink_trend") or {}
            return bool(tr.get("declining")) and (tr.get("drop_pct") or 0) >= thr, tr.get("drop_pct")
        if tid == "posture_drift":
            return len(g("posture_issues") or []) >= thr, len(g("posture_issues") or [])
        if tid == "long_stare":
            return (g("current_stare_s") or 0) > thr, g("current_stare_s")
        if tid == "incomplete_blinks":
            return g("incomplete_pct") is not None and m["incomplete_pct"] > thr, g("incomplete_pct")
        if tid == "drowsy":
            return (g("perclos") or 0) > thr, g("perclos")
        if tid == "long_blinks":
            return g("long_blink_count", 0) >= thr, g("long_blink_count")
        if tid == "sustained_squint":
            return bool(g("squinting")), g("squint_delta")
        if tid == "too_close":
            return g("distance_cm") is not None and not g("distance_stale") and m["distance_cm"] < thr, g("distance_cm")
        if tid == "eye_rub":
            return "rub" in kinds, 1
        if tid == "yawning":
            return g("yawn_count_5m", 0) >= thr, g("yawn_count_5m")
        if tid == "dark_room_bright_screen":
            ok = (g("room_luma") is not None and m["room_luma"] < 60 and (g("screen_luma") or 0) > 170
                  and g("dark_mode") is False)
            return ok, g("room_luma")
        if tid == "no_break":
            return g("since_real_break_s", 0) > thr, g("since_real_break_s")
        if tid == "break_taken":
            return "break" in kinds, 1
        if tid == "heartbeat":
            return bool(g("face_present")), None
        return False, None

    def take(self, now, busy, s, interruptible=True):
        """Pop the merged trigger list if a run may start now, else None.

        interruptible: the conductor's call on whether this is a good moment. When it isn't, non-priority triggers
        stay queued (and expire after STALE_S) instead of waking the agent.
        """
        for tid in [k for k, t in self.pending.items() if now - t.get("fired_at", now) > STALE_S]:
            del self.pending[tid]
        if busy or not self.pending:
            return None
        if not interruptible and not set(self.pending) & PRIORITY:
            return None
        gap = 30 if s["demo.enabled"] else s["agent.global_gap_s"]
        hb = 180 if s["demo.enabled"] else s["agent.heartbeat_s"]
        ids = set(self.pending)
        if ids == {"heartbeat"} and now - self.last_event_run < hb:
            self.pending.clear()  # heartbeat skipped: another trigger ran recently
            return None
        if ids == {"break_taken"}:
            return None  # only useful merged with something else; outcomes handle it
        if now - self.last_run < gap and not ids & PRIORITY:
            return None
        trig = list(self.pending.values())
        self.pending.clear()
        self.last_run = now
        if ids - {"heartbeat"}:
            self.last_event_run = now
        return trig

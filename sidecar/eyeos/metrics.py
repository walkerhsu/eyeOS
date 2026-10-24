"""Eye-strain metrics (SPEC §4). Pure functions + one rolling-window engine.

A frame is a dict: {ts, face: [[x,y,z]*478] | None, blend: {name: score},
transform: [16] row-major | None, hands: [[[x,y,z]*21], ...], luma: float | None, w, h}.
"""
import math
import statistics
import time
from collections import deque

R_EAR = (33, 160, 158, 133, 153, 144)
L_EAR = (362, 385, 387, 263, 373, 380)
FINGERTIPS = (4, 8, 12, 16, 20)
IRIS_MM = 11.7

DEFAULT_ADV = {"dip_start_o": 0.75, "dip_end_o": 0.85,
               "complete_o": 0.35,        # quick natural blinks bottom out at 0.2-0.4 at 30 fps; only slow ones reach 0.2
               "perclos_o": 0.20,         # PERCLOS "closed" = lids >= 80% shut; sustained closure does reach it
               "incomplete_max_o": 0.60, "long_blink_s": 0.5, "real_break_s": 20,
               "talk_jaw_std": 0.035,     # jaw-open std over 2 s above this = speaking (talking raises blink rate ~50%)
               "trend_window_min": 12}    # blink-rate decline window

DEFAULT_CAL = {"ear_open": 0.28, "squint_score": 0.0, "w_px_cal": None, "distance_cm": 60,
               "yaw0": 0.0, "pitch0": 0.0, "roll0": 0.0,
               "gx_min": 0.35, "gx_max": 0.65, "gy_min": 0.2, "gy_max": 0.8,
               "blink_rate": None, "blink_duration_ms": None, "calibrated": False}


# ---------- pure functions ----------

def dist(a, b, w=1.0, h=1.0):
    return math.hypot((a[0] - b[0]) * w, (a[1] - b[1]) * h)


def ear(pts, idx, w=1.0, h=1.0):
    p1, p2, p3, p4, p5, p6 = (pts[i] for i in idx)
    horiz = dist(p1, p4, w, h)
    if horiz == 0:
        return 0.0
    return (dist(p2, p6, w, h) + dist(p3, p5, w, h)) / (2 * horiz)


def openness(ear_value, baseline):
    return max(0.0, min(1.2, ear_value / baseline))


def iris_width_px(face, w, h):
    return (dist(face[469], face[471], w, h) + dist(face[474], face[476], w, h)) / 2


def distance_cm(w_px, w_px_cal=None, d_cal_cm=60, frame_w=640):
    if not w_px:
        return None
    if w_px_cal:
        return d_cal_cm * w_px_cal / w_px
    return (frame_w * IRIS_MM / w_px) / 10  # uncalibrated: f_px = frame width


def _ratio(v, a, b):
    return (v - a) / (b - a) if b != a else 0.5


def gaze(face):
    gx_r = _ratio(face[468][0], face[33][0], face[133][0])
    gx_l = _ratio(face[473][0], face[263][0], face[362][0])
    gy_r = _ratio(face[468][1], face[159][1], face[145][1])
    gy_l = _ratio(face[473][1], face[386][1], face[374][1])
    return (gx_r + gx_l) / 2, (gy_r + gy_l) / 2


def head_pose(m16):
    """Yaw, pitch, roll in degrees from a row-major 4x4 transform."""
    r = [m16[0:3], m16[4:7], m16[8:11]]
    pitch = math.degrees(math.atan2(r[2][1], r[2][2]))
    yaw = math.degrees(math.asin(max(-1.0, min(1.0, -r[2][0]))))
    roll = math.degrees(math.atan2(r[1][0], r[0][0]))
    return yaw, pitch, roll


def eye_center(face, idx):
    return (sum(face[i][0] for i in idx) / 6, sum(face[i][1] for i in idx) / 6)


def mar(face, w=1.0, h=1.0):
    horiz = dist(face[78], face[308], w, h)
    return dist(face[13], face[14], w, h) / horiz if horiz else 0.0


def verdict(metric, before, after, face_frac=1.0):
    """Outcome verdict (§9.7). Good direction is up for blink_rate, down for the rest."""
    if face_frac < 0.5 or before is None or after is None:
        return "inconclusive"
    up_is_good = metric in ("blink_rate", "distance_cm")
    delta = (after - before) if up_is_good else (before - after)
    if metric == "blink_rate" and abs(after - before) >= 2:
        return "improved" if delta > 0 else "worse"
    rel = delta / abs(before) if before else (1.0 if delta > 0 else -1.0 if delta < 0 else 0.0)
    if rel >= 0.15:
        return "improved"
    if rel <= -0.15:
        return "worse"
    return "neutral"


# ---------- dip state machine (§4.3) ----------

class DipDetector:
    def __init__(self, adv):
        self.adv = adv
        self.state = "OPEN"
        self.start = 0.0
        self.min_o = 1.0
        self.frames = 0

    def update(self, t, o):
        """Returns an event dict or None."""
        a = self.adv
        if self.state == "OPEN":
            if o < a["dip_start_o"]:
                self.state, self.start, self.min_o, self.frames = "DIP", t, o, 1
            return None
        if self.state == "DIP":
            self.min_o = min(self.min_o, o)
            if o > a["dip_end_o"]:
                self.state = "OPEN"
                return self._classify(t)
            self.frames += 1
            if t - self.start > 3.0:
                self.state = "CLOSED"
            return None
        if o > a["dip_end_o"]:  # CLOSED
            self.state = "OPEN"
            return {"kind": "eyes_closed", "start": self.start, "end": t, "duration": t - self.start}
        return None

    def _classify(self, end):
        a = self.adv
        if self.frames < 2:
            return None
        dur = end - self.start
        if self.min_o <= a["complete_o"]:
            return {"kind": "blink", "start": self.start, "end": end, "duration": dur,
                    "min_o": self.min_o, "long": dur > a["long_blink_s"]}
        if self.min_o <= a["incomplete_max_o"]:
            return {"kind": "incomplete", "start": self.start, "end": end, "duration": dur, "min_o": self.min_o}
        return None


# ---------- engine ----------

class Engine:
    def __init__(self, cal=None, adv=None, today_s=0.0):
        self.cal = {**DEFAULT_CAL, **(cal or {})}
        self.adv = {**DEFAULT_ADV, **(adv or {})}
        self.dip = DipDetector(self.adv)
        self.frames = deque()        # (ts, face_present, closed, on_screen, talking) for 60 s
        self.blinks = deque()        # (end_ts, duration, long, talking)
        self.incompletes = deque()   # (end_ts, talking)
        self.jaw = deque()           # (ts, jaw_open) 2 s, for talking detection
        self.talk_until = 0.0
        self.trend = deque()         # (ts, blink_rate, blink_duration_s) every 10 s, ~20 min
        self.trend_next = 0.0
        self.posture = deque()       # (ts, pitch, roll, nose_y, distance) 30 s
        self.posture_ref = None      # medians from the first 3 min of the session
        self.posture_ref_samples = []
        self.posture_session = None
        self.posture_off_since = None
        self.pose_feat = None        # latest upper-body geometry from MediaPipe Pose (+ ts)
        self.stares = deque()        # (ts, gap_s) recorded at each dip start, 5 min
        self.open_samples = deque()  # (ts, squint_score, o) 10 s, open frames only
        self.luma = deque()          # (ts, luma) 5 s
        self.dist_raw = deque(maxlen=15)
        self.yawns = deque()
        self.ts_hist = deque(maxlen=60)
        self.last = {}               # last computed values for the snapshot
        self.stare_acc = 0.0
        self.distance = None
        self.distance_stale = False
        self.last_face_ts = None
        self.last_face = None
        self.last_ts = None
        self.away_since = None
        self.last_break_end = None
        self.presence_start = None
        self.session_start = None
        self.today_s = today_s
        self.today_date = time.strftime("%Y-%m-%d")
        self.squint_since = None
        self.rub_near = deque()      # (ts, dt) of near-hand hand frames, 1.5 s
        self.rub_last = -1e9
        self.rubbing = False
        self.yawn_start = None
        self.screen_luma = None
        self.dark_mode = None
        self.started = None
        self.recorder = None         # optional callable(sample) for calibration

    # --- external state ---
    def set_screen(self, screen_luma, dark_mode):
        self.screen_luma, self.dark_mode = screen_luma, dark_mode

    def set_cal(self, cal):
        self.cal.update(cal)

    # --- per frame ---
    def update(self, f):
        t = f["ts"]
        events = []
        dt = 0.0 if self.last_ts is None else min(t - self.last_ts, 0.5)
        self.last_ts = t
        self.started = self.started or t
        self.ts_hist.append(t)
        w, h = f.get("w", 640), f.get("h", 480)
        face = f.get("face")
        present = face is not None

        if f.get("luma") is not None:
            self.luma.append((t, f["luma"]))
        _trim(self.luma, t - 5)

        # presence / session / today
        if present:
            if self.last_face_ts is None or t - self.last_face_ts >= 5:
                self.presence_start = t
            if self.session_start is None or (self.last_face_ts is not None and t - self.last_face_ts >= 120):
                self.session_start = t
                self.last_break_end = t
            self.last_face_ts, self.last_face = t, face
            day = time.strftime("%Y-%m-%d", time.localtime(t))
            if day != self.today_date:
                self.today_date, self.today_s = day, 0.0
            self.today_s += dt

        closed = False
        on_screen = False
        sample = {"ts": t, "present": present}
        if present:
            e = (ear(face, R_EAR, w, h) + ear(face, L_EAR, w, h)) / 2
            o = openness(e, self.cal["ear_open"])
            closed = o <= self.adv["perclos_o"]
            gx, gy = gaze(face)
            yaw = pitch = roll = 0.0
            if f.get("transform"):
                yaw, pitch, roll = head_pose(f["transform"])
                sample.update(yaw_raw=yaw, pitch_raw=pitch, roll_raw=roll)
                yaw -= self.cal["yaw0"]
                pitch -= self.cal["pitch0"]
                roll -= self.cal["roll0"]
            on_screen = (self.cal["gx_min"] - 0.05 <= gx <= self.cal["gx_max"] + 0.05
                         and abs(yaw) < 25 and pitch > -35)

            # dips
            prev_state = self.dip.state
            ev = self.dip.update(t, o)
            if prev_state == "OPEN" and self.dip.state == "DIP":
                self.stares.append((t, self.stare_acc))
            if ev:
                ev["ts"] = t
                if ev["kind"] == "blink":
                    self.blinks.append((t, ev["duration"], ev["long"], t < self.talk_until))
                elif ev["kind"] == "incomplete":
                    self.incompletes.append((t, t < self.talk_until))
                if ev["kind"] in ("blink", "incomplete"):
                    self.stare_acc = 0.0
                events.append(ev)
            if self.dip.state == "OPEN" and on_screen:
                self.stare_acc += dt

            # squint (open frames only)
            blend = f.get("blend") or {}
            sq = (blend.get("eyeSquintLeft", 0) + blend.get("eyeSquintRight", 0)) / 2
            br = (blend.get("browDownLeft", 0) + blend.get("browDownRight", 0)) / 2
            score = sq + 0.5 * br
            if self.dip.state == "OPEN":
                self.open_samples.append((t, score, o))
            sample.update(ear=e, o=o, gx=gx, gy=gy, squint_score=score, state=self.dip.state)

            # talking: the jaw moves rhythmically while speaking (blendshape, else mouth aspect ratio)
            jaw = blend.get("jawOpen")
            self.jaw.append((t, jaw if jaw is not None else min(1.0, mar(face, w, h))))
            _trim(self.jaw, t - 2)
            if len(self.jaw) >= 8 and statistics.pstdev(j for _, j in self.jaw) > self.adv["talk_jaw_std"]:
                self.talk_until = t + 1.5  # short hangover between words

            # distance
            wpx = iris_width_px(face, w, h)
            sample["w_px"] = wpx
            if abs(yaw) > 30:
                self.distance_stale = True
            else:
                self.distance_stale = False
                d = distance_cm(wpx, self.cal["w_px_cal"], self.cal["distance_cm"], w)
                if d:
                    self.dist_raw.append(d)
                    med = statistics.median(self.dist_raw)
                    self.distance = med if self.distance is None else self.distance + 0.1 * (med - self.distance)

            # yawn
            jaw = blend.get("jawOpen")
            yawn_open = jaw > 0.60 if jaw is not None else mar(face, w, h) > 0.6
            if yawn_open:
                self.yawn_start = self.yawn_start or t
            else:
                if self.yawn_start is not None and t - self.yawn_start >= 1.5:
                    self.yawns.append(t)
                    events.append({"kind": "yawn", "ts": t, "duration": t - self.yawn_start})
                self.yawn_start = None

            if f.get("pose") is not None:
                pf = self._pose_features(f["pose"], w, h)
                self.pose_feat = {**pf, "ts": t} if pf else None
            self.last.update(o=o, ear=e, gx=gx, gy=gy, yaw=yaw, pitch=pitch, roll=roll)
            self._posture_sample(t, pitch, roll, face[1][1])

        # rubbing (§4.9): hand frames only; face dropout during near doesn't reset
        hands = f.get("hands")
        if hands is not None and self.last_face is not None:
            lf = self.last_face
            iod = dist(lf[33], lf[263], w, h)
            centers = (eye_center(lf, R_EAR), eye_center(lf, L_EAR))
            md = min((dist(hand[i], c, w, h) for hand in hands for i in FINGERTIPS for c in centers), default=1e9)
            near = md < 0.35 * iod
            self.rubbing = near
            prev = self.rub_near[-1][0] if self.rub_near else None
            if near:
                self.rub_near.append((t, min(t - prev, 0.2) if prev else 0.1))
            _trim(self.rub_near, t - 1.5)
            if sum(d for _, d in self.rub_near) >= 0.7 and t - self.rub_last >= 30:
                self.rub_last = t
                self.rub_near.clear()
                events.append({"kind": "rub", "ts": t})

        # looking away / real breaks (§4.8)
        away = not present or not on_screen
        if away:
            self.away_since = self.away_since or t
        else:
            if self.away_since is not None and t - self.away_since >= self.adv["real_break_s"]:
                self.last_break_end = t
                events.append({"kind": "break", "ts": t, "duration": t - self.away_since})
            self.away_since = None

        # squint sustain
        talking = present and t < self.talk_until
        self.frames.append((t, present, closed, on_screen, talking))
        _trim(self.frames, t - 60)
        _trim(self.blinks, t - 60)
        _trim(self.incompletes, t - 60)
        if t >= self.trend_next:
            self.trend_next = t + 10
            br, _, _ = self._blink_stats()
            dur = statistics.fmean(d for _, d, _, k in self.blinks if not k) if any(not b[3] for b in self.blinks) else None
            if br is not None:
                self.trend.append((t, br, dur))
            _trim(self.trend, t - 60 * (self.adv["trend_window_min"] + 3))
        _trim(self.stares, t - 300)
        _trim(self.open_samples, t - 10)
        _trim(self.yawns, t - 300)
        squinting = self._squinting()
        if squinting:
            self.squint_since = self.squint_since or t
        else:
            self.squint_since = None

        if self.recorder:
            self.recorder(sample)
        return events

    def _squinting(self):
        if not self.open_samples:
            return False
        delta = statistics.fmean(s for _, s, _ in self.open_samples) - self.cal["squint_score"]
        ratio = statistics.fmean(o for _, _, o in self.open_samples)
        self.last["squint_delta"], self.last["open_ratio"] = delta, ratio
        return delta > 0.15 or ratio < 0.80

    def _blink_stats(self):
        """(blink_rate, incomplete_pct, quiet_min) over the last 60 s, counting only time you weren't talking."""
        quiet = sum(1 for x in self.frames if x[1] and not x[4])
        span = (self.frames[-1][0] - self.frames[0][0]) if len(self.frames) > 1 else 0
        quiet_min = (quiet / len(self.frames)) * span / 60 if self.frames else 0
        n_blink = sum(1 for b in self.blinks if not b[3])
        n_inc = sum(1 for i in self.incompletes if not i[1])
        rate = n_blink / quiet_min if quiet_min > 0.25 else None  # need >= 15 s of quiet face time
        pct = n_inc / (n_blink + n_inc) if n_blink + n_inc >= 5 else None
        return rate, pct, quiet_min

    def blink_trend(self):
        """Blink rate per minute over the trend window, and whether it is steadily declining (16 -> 14 -> 12 -> 10)."""
        if not self.trend:
            return None
        t1 = self.trend[-1][0]
        win = self.adv["trend_window_min"]
        mins = []
        for m in range(win, 0, -1):
            v = [(r, d) for ts, r, d in self.trend if t1 - m * 60 < ts <= t1 - (m - 1) * 60]
            if v:
                ds = [d for _, d in v if d is not None]
                mins.append((win - m, statistics.fmean(r for r, _ in v), statistics.fmean(ds) if ds else None))
        if len(mins) < max(6, int(win * 0.6)):
            return {"minutes": [round(r, 1) for _, r, _ in mins], "declining": False, "ready": False}
        xs, ys = [x for x, _, _ in mins], [y for _, y, _ in mins]
        mx, my = statistics.fmean(xs), statistics.fmean(ys)
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (sum((x - mx) ** 2 for x in xs) or 1)
        start, end = statistics.fmean(ys[:3]), statistics.fmean(ys[-3:])
        drop = (start - end) / start if start > 0 else 0.0
        smooth = [statistics.fmean(ys[i:i + 3]) for i in range(len(ys) - 2)]
        steady = sum(1 for a, b in zip(smooth, smooth[1:]) if b <= a + 0.3) / max(1, len(smooth) - 1)
        d0 = [d for _, _, d in mins[:3] if d is not None]
        d1 = [d for _, _, d in mins[-3:] if d is not None]
        dur_change = (statistics.fmean(d1) / statistics.fmean(d0) - 1) if d0 and d1 and statistics.fmean(d0) > 0 else None
        return {"minutes": [round(y, 1) for y in ys], "start": round(start, 1), "end": round(end, 1),
                "drop_pct": round(drop, 3), "slope_per_min": round(slope, 2), "steady": round(steady, 2),
                "blink_duration_change": None if dur_change is None else round(dur_change, 3), "ready": True,
                "declining": drop >= 0.2 and start - end >= 3 and slope < -0.2 and steady >= 0.7}

    def _pose_features(self, pose, w, h):
        """Upper-body geometry from MediaPipe Pose (front camera), or None when the shoulders aren't visible.

        neck: nose height above the shoulder line / shoulder width (shrinks when slumping or shrugging)
        tilt: shoulder-line angle in degrees; lean: nose offset from the shoulder midpoint / shoulder width
        width: shoulder width / frame width (grows when leaning in); shoulder_y: shoulder midpoint height (0-1)
        """
        if not pose or len(pose) < 13 or min(pose[11][3], pose[12][3]) < 0.6:
            return None
        ls, rs, nose = pose[11], pose[12], pose[0]
        sw = math.hypot((ls[0] - rs[0]) * w, (ls[1] - rs[1]) * h)
        if sw < 1:
            return None
        mx, my = (ls[0] + rs[0]) / 2, (ls[1] + rs[1]) / 2
        tilt = math.degrees(math.atan2((ls[1] - rs[1]) * h, abs(ls[0] - rs[0]) * w))
        return {"neck": (my - nose[1]) * h / sw, "tilt": tilt, "lean": (nose[0] - mx) * w / sw,
                "width": sw / w, "shoulder_y": my}

    def _posture_sample(self, t, pitch, roll, nose_y):
        if self.posture_session != self.session_start:  # new sitting: learn a fresh reference posture
            self.posture_session, self.posture_ref, self.posture_ref_samples = self.session_start, None, []
            self.posture_off_since = None
        p = self.pose_feat if self.pose_feat and t - self.pose_feat["ts"] < 1.0 else {}
        row = (t, pitch, roll, nose_y, self.distance,
               p.get("neck"), p.get("tilt"), p.get("lean"), p.get("width"), p.get("shoulder_y"))
        self.posture.append(row)
        _trim(self.posture, t - 30)
        if self.posture_ref is None:
            self.posture_ref_samples.append(row)
            if t - self.posture_ref_samples[0][0] >= 180 and len(self.posture_ref_samples) >= 100:
                self.posture_ref = self._medians(self.posture_ref_samples)
                self.posture_ref_samples = []

    @staticmethod
    def _medians(rows):
        cols = list(zip(*rows))[1:]
        return tuple(statistics.median([v for v in c if v is not None]) if any(v is not None for v in c) else None for c in cols)

    def posture_reference(self, seconds=3):
        """Medians of the last few seconds: saved at calibration step 1 ("sit at arm's length") as a good posture."""
        rows = [r for r in self.posture if r[0] >= (self.last_ts or 0) - seconds]
        return list(self._medians(rows)) if rows else None

    def posture_state(self, t):
        """How your posture has drifted from the start of this session (or, until that's learned, from calibration)."""
        cal_ref = self.cal.get("posture_ref")
        ref = self.posture_ref or (tuple(cal_ref) if cal_ref and len(cal_ref) == 9 else None)
        if ref is None or len(self.posture) < 30:
            return {"ready": False, "issues": [], "off_s": 0}
        pitch, roll, y, d, neck, tilt, lean, width, sy = self._medians(self.posture)
        rp, rr, ry, rd, rneck, rtilt, rlean, rwidth, rsy = ref
        both = lambda a, b: a is not None and b is not None  # noqa: E731
        issues = []
        if both(neck, rneck) and rneck > 0:  # shoulders visible: real upper-body geometry
            if neck < 0.85 * rneck:
                # the head sank toward the shoulders: either the shoulders came up (tension) or the head went down
                issues.append("shoulders_raised" if both(sy, rsy) and sy - rsy < -0.03 else "slumping")
            if both(tilt, rtilt) and abs(tilt - rtilt) > 6:
                issues.append("shoulders_uneven")
            if both(lean, rlean) and abs(lean - rlean) > 0.15:
                issues.append("leaning_sideways")
            if both(width, rwidth) and width > 1.15 * rwidth:
                issues.append("leaning_in")
        elif both(y, ry) and y - ry > 0.06:
            issues.append("slumping")       # face only: head sits lower in the frame than when you started
        if both(pitch, rp) and pitch - rp < -12:
            issues.append("head_dropping")  # chin dropping toward the chest
        if both(roll, rr) and abs(roll - rr) > 10:
            issues.append("head_tilted")
        if "leaning_in" not in issues and d is not None and rd and d < 0.85 * rd:
            issues.append("leaning_in")
        if issues:
            self.posture_off_since = self.posture_off_since or t
        else:
            self.posture_off_since = None
        return {"ready": True, "issues": issues, "off_s": round(t - self.posture_off_since) if self.posture_off_since else 0,
                "source": "pose" if both(neck, rneck) else "face",
                "delta": {"pitch_deg": _r(pitch - rp if both(pitch, rp) else None, 1),
                          "roll_deg": _r(roll - rr if both(roll, rr) else None, 1),
                          "neck_ratio": _r(neck / rneck if both(neck, rneck) and rneck else None, 2),
                          "shoulder_tilt_deg": _r(tilt - rtilt if both(tilt, rtilt) else None, 1),
                          "lean": _r(lean - rlean if both(lean, rlean) else None, 2),
                          "distance_ratio": _r(d / rd if d and rd else None, 2)}}

    def snapshot(self, now=None):
        t = now or self.last_ts or time.time()
        present_frames = sum(1 for x in self.frames if x[1])
        span = (self.frames[-1][0] - self.frames[0][0]) if len(self.frames) > 1 else 0
        present_min = (present_frames / len(self.frames)) * span / 60 if self.frames else 0
        n_inc = len(self.incompletes)
        blink_rate, incomplete_pct, _ = self._blink_stats()
        talking = bool(self.frames and self.frames[-1][4])
        talk_frames = sum(1 for x in self.frames if x[1] and x[4])
        posture = self.posture_state(t)
        face_present = self.last_face_ts is not None and t - self.last_face_ts <= 0.5
        fps = (len(self.ts_hist) - 1) / (self.ts_hist[-1] - self.ts_hist[0]) if len(self.ts_hist) > 1 and self.ts_hist[-1] > self.ts_hist[0] else 0
        room = statistics.fmean(l for _, l in self.luma) if self.luma else None
        L = self.last
        return {
            "ts": t,
            "face_present": face_present,
            "o": _r(L.get("o")), "ear": _r(L.get("ear"), 3),
            "blink_rate": _r(blink_rate, 1),
            "baseline_blink_rate": self.cal.get("blink_rate"),
            "talking": talking, "talking_pct": _r(talk_frames / present_frames) if present_frames else 0,
            "blink_trend": self.blink_trend(),
            "posture_issues": posture["issues"], "posture_off_s": posture["off_s"], "posture_ready": posture["ready"],
            "posture_delta": posture.get("delta"),
            "incomplete_rate": _r(n_inc / present_min, 1) if present_min > 0.1 else None,
            "incomplete_pct": _r(incomplete_pct),
            "blink_duration_ms": round(1000 * statistics.fmean(b[1] for b in self.blinks)) if self.blinks else None,
            "long_blink_count": sum(1 for b in self.blinks if b[2] and not b[3]),
            "current_stare_s": _r(self.stare_acc, 1),
            "longest_stare_s": _r(max([g for _, g in self.stares] + [self.stare_acc]), 1),
            "perclos": _r(sum(1 for x in self.frames if x[1] and x[2]) / present_frames, 3) if present_frames else None,
            "squint_delta": _r(L.get("squint_delta")), "open_ratio": _r(L.get("open_ratio")),
            "squinting": self._squinting(),
            "squint_s": _r(t - self.squint_since, 1) if self.squint_since else 0,
            "distance_cm": _r(self.distance, 1), "distance_stale": self.distance_stale,
            "yaw_deg": _r(L.get("yaw"), 1), "pitch_deg": _r(L.get("pitch"), 1), "roll_deg": _r(L.get("roll"), 1),
            "gx": _r(L.get("gx")), "gy": _r(L.get("gy")),
            "gaze_on_screen": bool(self.frames and self.frames[-1][3]),
            "rubbing": self.rubbing,
            "yawn_count_5m": len(self.yawns),
            "room_luma": _r(room, 0),
            "screen_luma": self.screen_luma, "dark_mode": self.dark_mode,
            "presence_s": round(t - self.presence_start) if self.presence_start and face_present else 0,
            "session_s": round(t - self.session_start) if self.session_start else 0,
            "since_real_break_s": round(t - (self.last_break_end or self.started or t)),
            "screen_time_today_s": round(self.today_s),
            "fps": _r(fps, 1),
            "calibrated": bool(self.cal.get("calibrated")),
        }


def _trim(dq, cutoff, key=lambda x: x[0] if isinstance(x, tuple) else x):
    while dq and key(dq[0]) < cutoff:
        dq.popleft()


def _r(v, n=2):
    return None if v is None else round(v, n)

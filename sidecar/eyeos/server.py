"""The sidecar hub: vision thread, WebSocket server, trigger/agent scheduling (SPEC §2, §6)."""
import asyncio
import collections
import datetime as dt
import gzip
import json
import os
import statistics
import struct
import sys
import threading
import time
import traceback
import uuid
from urllib.parse import parse_qs, urlparse

import cv2

from . import demo
from . import tools as T
from .agent import CLIS, Agent
from .db import DB, TRIGGERS, validate_setting
from .metrics import Engine
from .screen_watch import ScreenWatch
from .tools import system as S
from .triggers import Triggers
from .tts import Speaker
from .zen import Zen, eye_score, recap_stats

VERSION = "0.1.0"
EVENT_KIND = {"rub": "rub", "yawn": "yawn", "break": "break", "eyes_closed": "blink_anomaly", "blink": "blink_anomaly"}
CAL_SECONDS = {1: 3, 2: 10, 3: 60}
HISTORY_KEYS = ("blink_rate", "perclos", "distance_cm", "squint_delta", "incomplete_pct", "eye_score", "current_stare_s",
                "longest_stare_s", "gaze_on_screen", "blink_duration_ms", "since_real_break_s", "zen")


class App:
    def __init__(self, port=None, token=None, print_mode=False, replay=None, record=None, db_path=None):
        self.port, self.token = port, token
        self.print_mode, self.replay, self.record = print_mode, replay, record
        self.db = DB(db_path) if db_path else DB()
        self.settings = self.db.settings()
        self.lock = threading.Lock()
        self.engine = Engine(cal=self.db.baseline(), adv=self._adv(), today_s=self._today_s())
        self.triggers = Triggers()
        self.zen = Zen()
        self.today = {}
        self.speaker = Speaker(lambda: self.settings)
        self.agent = Agent(self)
        self.screen = ScreenWatch(lambda: self.settings, lambda: bool(self.snapshot.get("face_present")))
        self.ws = None
        self.loop = None
        self.futures = {}
        self.snapshot = self.engine.snapshot()
        self.history = collections.deque(maxlen=1800)  # 1 Hz snapshots, 30 min
        self.active = {"name": "", "bundle_id": "", "window_title": "", "category": "other"}
        self.typing_hist = collections.deque(maxlen=90)
        self.last_action = None
        self.frame = None          # latest unmirrored BGR frame
        self.landmarks = None
        self.camera_ok = False
        self.stop = threading.Event()
        self.last_status = None
        self.pending_events = []
        self.done = None
        self.thread = None

    def _adv(self):
        return {k[9:]: v for k, v in self.settings.items() if k.startswith("advanced.")}

    def _today_s(self):
        d0 = dt.datetime.combine(dt.date.today(), dt.time()).timestamp()
        r = self.db.q("SELECT MAX(json_extract(data, '$.screen_time_today_s')) s FROM metrics_1hz WHERE ts >= ? AND seeded=0", (d0,))
        return r[0]["s"] or 0

    # ---------- vision thread ----------

    def vision_thread(self):
        from .camera import Camera
        from .vision import Vision
        vision = None if self.replay else Vision()
        cam = Camera()
        rec = gzip.open(self.record, "wt") if self.record else None
        replay = gzip.open(self.replay, "rt") if self.replay else None
        offset = None
        try:
            while not self.stop.is_set():
                if self.settings["tracking.paused"] and not self.replay:
                    if cam.cap is not None:
                        cam.release()
                        self.camera_ok = False
                    time.sleep(0.2)
                    continue
                if replay:
                    line = replay.readline()
                    if not line:
                        break
                    f = json.loads(line)
                    offset = offset if offset is not None else time.time() - f["ts"]
                    time.sleep(max(0, f["ts"] + offset - time.time()))
                    f["ts"] += offset
                    bgr = None
                    self.camera_ok = True
                else:
                    if cam.cap is None:
                        self.camera_ok = cam.open()
                        if not self.camera_ok:
                            cam.release()
                            time.sleep(2)
                            continue
                    ts, bgr = cam.read()
                    if bgr is None:
                        self.camera_ok = False
                        cam.release()
                        time.sleep(1)
                        continue
                    f = vision.process(bgr, ts)
                    if rec:
                        rec.write(json.dumps({k: f[k] for k in ("ts", "w", "h", "face", "blend", "transform", "hands", "luma")}) + "\n")
                with self.lock:
                    events = self.engine.update(f)
                self.frame = bgr
                if f["face"] is not None or f["hands"] is not None:
                    self.landmarks = {"face": f["face"] if f["face"] is not None else None,
                                      "hands": f["hands"] if f["hands"] is not None else (self.landmarks or {}).get("hands", []),
                                      "ts": f["ts"], "o": self.engine.last.get("o") if f["face"] is not None else None}
                if f["face"] is None and self.landmarks:
                    self.landmarks["face"] = None
                if events and self.loop:
                    self.loop.call_soon_threadsafe(self.on_events, events)
        except Exception:  # noqa: BLE001
            traceback.print_exc()
        finally:
            cam.release()
            if rec:
                rec.close()
            if vision:
                vision.close()
            if replay and self.loop:
                self.loop.call_soon_threadsafe(self._finish)

    # ---------- events / triggers / agent ----------

    def on_events(self, events):
        """Called on the asyncio thread with events from the vision thread."""
        self.pending_events.extend(events)
        for e in events:
            k = e["kind"]
            details = {kk: v for kk, v in e.items() if kk not in ("ts", "kind")}
            if k in ("blink", "incomplete"):
                dip = "long_blink" if k == "blink" and e["long"] else k
                # every dip goes to the UI for the dip trace; only long blinks are persisted
                self._send_soon({"type": "event", "id": None, "ts": e["ts"], "kind": "dip", "trigger_id": None,
                                 "value": e["min_o"], "details": {"dip": dip, "duration": e["duration"]}})
                if dip != "long_blink":
                    continue
            self.log_event(EVENT_KIND.get(k, "system"), None, e.get("duration"), {"event": k, **details}, e["ts"])

    def log_event(self, kind, trigger_id, value, details, ts=None):
        ts = ts or time.time()
        eid = self.db.x("INSERT INTO events (ts, kind, trigger_id, value, details) VALUES (?, ?, ?, ?, ?)",
                        (ts, kind, trigger_id, value, json.dumps(details, default=str)))
        self._send_soon({"type": "event", "id": eid, "ts": ts, "kind": kind, "trigger_id": trigger_id,
                         "value": value, "details": details})
        return eid

    def _send_soon(self, msg):
        asyncio.ensure_future(self.send(msg))

    async def tick_5hz(self):
        while True:
            await asyncio.sleep(0.2)
            try:
                with self.lock:
                    snap = self.engine.snapshot(time.time())
                snap["app_category"] = self.active.get("category")
                if snap["app_category"] == "call":  # talking on calls raises blinking ~50%: don't judge blinks then
                    snap["blink_rate"] = snap["incomplete_pct"] = None
                    snap["talking"] = True
                snap["eye_score"] = eye_score(snap, self.engine.cal)
                snap["zen"] = self.zen.active
                self.snapshot = snap
                events, self.pending_events = self.pending_events, []
                await self.send({"type": "metrics", **snap})
                s = self.settings
                last_face = self.engine.last_face_ts or 0
                active = (not s["tracking.paused"] and snap["calibrated"] and time.time() - last_face < 120)
                for t in self.triggers.evaluate(snap, events, s, time.time(), active):
                    t["event_id"] = self.log_event("trigger", t["id"], t["value"], {"demo": s["demo.enabled"], "zen": self.zen.active},
                                                   t["fired_at"])
                    if self.zen.active and t["id"] not in ("heartbeat", "break_taken"):
                        self.zen.held_back += 1
                if self.zen.active:
                    self.triggers.pending.clear()  # Zen: keep recording, never wake the agent
                    continue
                run = self.triggers.take(time.time(), self.agent.busy, s)
                if run and s["agent.enabled"] and self.agent.available():
                    asyncio.create_task(self.agent.run(run))
            except Exception:  # noqa: BLE001
                traceback.print_exc()

    async def tick_1hz(self):
        n = 0
        while True:
            await asyncio.sleep(1)
            n += 1
            snap = dict(self.snapshot)
            self.history.append(snap)
            if snap.get("face_present"):
                self.db.x("INSERT OR REPLACE INTO metrics_1hz (ts, data, app_category) VALUES (?, ?, ?)",
                          (snap["ts"], json.dumps(snap), snap.get("app_category")))
            try:
                self.typing_hist.append(S.seconds_since_key())
                input_age = S.seconds_since_input()
            except Exception:  # noqa: BLE001 - Quartz unavailable
                input_age = None
            if snap.get("calibrated") and not self.settings["tracking.paused"]:
                change = self.zen.tick(time.time(), snap, input_age, self.active.get("category"),
                                       self.settings["zen.enter_min"] * 60, self.settings["zen.enabled"])
                if change:
                    await self.zen_changed(*change)
            if n % 30 == 1:
                try:
                    self.today = self.today_stats()
                except Exception:  # noqa: BLE001
                    traceback.print_exc()
            await self.send_status(force=True)
            if n % 2 == 0:
                try:
                    self.active = await asyncio.to_thread(S.active_app)
                except Exception:  # noqa: BLE001
                    pass
            if n % 30 == 1 or self._screen_now:
                self._screen_now = False
                lum, dark = await asyncio.to_thread(S.screen_luma), await asyncio.to_thread(S.dark_mode)
                with self.lock:
                    self.engine.set_screen(lum, dark)

    _screen_now = False

    def refresh_screen_soon(self):
        self._screen_now = True

    def typing(self):
        h = list(self.typing_hist)
        last = h[-1] if h else None
        return {"seconds_since_last_key": None if last is None else round(last, 1),
                "typing_burst": last is not None and last < 2 and sum(1 for x in h if x < 2) >= 60}

    def trend_10m(self):
        now = time.time()
        out = []
        for m in range(10, 0, -1):
            rows = [h for h in self.history if now - m * 60 <= h["ts"] < now - (m - 1) * 60 and h.get("face_present")]
            if not rows:
                out.append({"minute": -m, "face_present": False})
                continue

            def mean(k):
                v = [r[k] for r in rows if r.get(k) is not None]
                return round(statistics.fmean(v), 3) if v else None
            cats = collections.Counter(r.get("app_category") for r in rows)
            out.append({"minute": -m, **{k: mean(k) for k in ("blink_rate", "incomplete_pct", "perclos", "distance_cm",
                                                              "squint_delta", "room_luma", "screen_luma")},
                        "gaze_on_screen_pct": round(sum(1 for r in rows if r.get("gaze_on_screen")) / len(rows), 2),
                        "app_category": cats.most_common(1)[0][0]})
        return out

    def webcam_jpeg(self, width=512):
        f = self.frame
        if f is None:
            return None
        h, w = f.shape[:2]
        img = cv2.resize(f, (width, int(h * width / w)))
        return cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 70])[1].tobytes()

    def update_baseline(self, reason):
        trig_ts = [r["ts"] for r in self.db.q("SELECT ts FROM events WHERE kind='trigger' AND ts > ?", (time.time() - 1800,))]
        rows = [h for h in self.history if h.get("face_present") and all(abs(h["ts"] - t) > 60 for t in trig_ts)]
        if len(rows) < 300:
            return False, f"not enough normal data in the last 30 min ({len(rows)} s, need 300)"
        cal = dict(self.engine.cal)
        ears = [r["ear"] for r in rows if r.get("ear") and (r.get("o") or 0) > 0.85]
        if ears:
            cal["ear_open"] = round(statistics.median(ears), 4)
        sd = [r["squint_delta"] for r in rows if r.get("squint_delta") is not None]
        if sd:
            cal["squint_score"] = round(cal["squint_score"] + statistics.median(sd), 4)
        br = [r["blink_rate"] for r in rows if r.get("blink_rate") is not None]
        if br:
            cal["blink_rate"] = round(statistics.median(br), 1)
        with self.lock:
            self.engine.set_cal(cal)
        self.db.save_baseline(cal, reason)
        return True, {k: cal[k] for k in ("ear_open", "squint_score", "blink_rate")}

    # ---------- Zen mode ----------

    async def zen_changed(self, change, info):
        if change == "enter":
            self.triggers.pending.clear()
            for rid, fut in list(self.futures.items()):  # close any open nudge or question: Zen means invisible
                if not fut.done():
                    await self.send({"type": "ui_dismiss", "request_id": rid})
                    fut.set_result(None)
            self.log_event("zen", None, None, {"event": "zen_start", "source": info["source"]})
        else:
            info["recap"] = self.zen_stats(info["since"], time.time())
            self.log_event("zen", None, info["duration_s"], {"event": "zen_end", **info})
            min_s = 20 if self.settings["demo.enabled"] else 60
            if info["reason"] != "away" and info["duration_s"] >= min_s:
                asyncio.create_task(self.zen_recap(info))
        self.today = self.today_stats()
        await self.send_status(force=True)

    def zen_stats(self, since, until):
        """Everything recorded while Zen kept eyeOS silent: metrics, events, and the alerts it held back."""
        rows = [json.loads(r["data"]) for r in self.db.q(
            "SELECT data FROM metrics_1hz WHERE ts >= ? AND ts <= ? AND seeded=0 ORDER BY ts", (since, until))]
        events = self.db.q("SELECT kind, trigger_id, value FROM events WHERE ts >= ? AND ts <= ? AND seeded=0 ORDER BY ts",
                           (since, until))
        return recap_stats(rows, events, self.engine.cal.get("blink_rate"),
                           self.settings["triggers.too_close.threshold"])

    async def zen_recap(self, info):
        base = self.engine.cal.get("blink_rate")
        br = info.get("blink_rate")
        bad = any(h["level"] == "bad" for h in info["recap"]["highlights"])
        rest = info["duration_s"] >= 1200 or bad or (br is not None and base and br < 0.7 * base)
        res = await self.ui_request("zen_recap", {**info, "baseline_blink_rate": base, "suggest_rest": bool(rest)}, 180)
        self.log_event("system", None, None, {"event": "zen_recap", "result": res})

    def today_stats(self):
        d0 = dt.datetime.combine(dt.date.today(), dt.time()).timestamp()
        ev = {r["kind"]: r["n"] for r in self.db.q("SELECT kind, COUNT(*) n FROM events WHERE ts >= ? AND seeded=0 GROUP BY kind", (d0,))}
        zen = self.db.q("SELECT COALESCE(SUM(value), 0) s, COALESCE(MAX(value), 0) m FROM events "
                        "WHERE kind='zen' AND value IS NOT NULL AND ts >= ? AND seeded=0", (d0,))[0]
        actions = [n for n in T.CATALOG if T.CATALOG[n][2] == "action"]
        nudges = self.db.q(f"SELECT COUNT(*) n FROM tool_calls WHERE ts >= ? AND status='done' AND seeded=0 "
                           f"AND name IN ({','.join('?' * len(actions))})", (d0, *actions))[0]["n"]
        avg = self.db.q("SELECT AVG(json_extract(data, '$.blink_rate')) b, AVG(json_extract(data, '$.eye_score')) e "
                        "FROM metrics_1hz WHERE ts >= ? AND seeded=0", (d0,))[0]
        cur = self.zen.state(time.time())["duration_s"]
        return {"screen_time_s": self.snapshot.get("screen_time_today_s") or 0, "breaks": ev.get("break", 0),
                "rubs": ev.get("rub", 0), "yawns": ev.get("yawn", 0), "nudges": nudges,
                "zen_s": round(zen["s"] + cur), "longest_zen_s": round(max(zen["m"], cur)),
                "avg_blink_rate": round(avg["b"], 1) if avg["b"] is not None else None,
                "avg_eye_score": round(avg["e"]) if avg["e"] is not None else None}

    # ---------- calibration (§7) ----------

    async def calibrate(self, step, args):
        if step not in CAL_SECONDS:
            return await self.send({"type": "error", "code": "bad_step", "message": f"unknown calibration step {step}"})
        samples, dips = [], []
        dur = CAL_SECONDS[step]
        with self.lock:
            self.engine.recorder = samples.append
        await self.send({"type": "calibration", "step": step, "phase": "started", "progress": 0, "seconds": dur})
        t0 = time.time()
        while time.time() - t0 < dur:
            await asyncio.sleep(0.2)
            p = min(1.0, (time.time() - t0) / dur)
            msg = {"type": "calibration", "step": step, "phase": "progress", "progress": round(p, 3)}
            if step == 2:
                msg["target"] = ["center", "top_left", "top_right", "bottom_right", "bottom_left"][min(4, int(p * 5))]
            await self.send(msg)
        with self.lock:
            self.engine.recorder = None
            blinks = [b for b in self.engine.blinks if b[0] >= t0]
        face = [s for s in samples if s["present"]]
        if not samples or len(face) < 0.5 * len(samples):
            return await self.send({"type": "calibration", "step": step, "phase": "failed", "progress": 1,
                                    "result": {"reason": "face not visible for most of the step; try again"}})
        cal = {}
        if step == 1:
            cal["w_px_cal"] = round(statistics.median(s["w_px"] for s in face), 3)
            cal["distance_cm"] = float(args.get("distance_cm") or self.settings["calibration.distance_cm"])
        elif step == 2:
            def med(rows, k):
                v = [r[k] for r in rows if k in r]
                return statistics.median(v) if v else 0.0
            per_dot = [[s for s in face if i * 2 <= s["ts"] - t0 < (i + 1) * 2] for i in range(5)]
            center = per_dot[0] or face
            cal.update(yaw0=med(center, "yaw_raw"), pitch0=med(center, "pitch_raw"), roll0=med(center, "roll_raw"))
            gxs = [med(d, "gx") for d in per_dot if d]
            gys = [med(d, "gy") for d in per_dot if d]
            cal.update(gx_min=min(gxs), gx_max=max(gxs), gy_min=min(gys), gy_max=max(gys))
        else:
            open_ = [s for s in face if s.get("state") == "OPEN"]
            cal["ear_open"] = round(statistics.median(s["ear"] for s in open_), 4) if open_ else 0.28
            cal["squint_score"] = round(statistics.median(s["squint_score"] for s in open_), 4) if open_ else 0.0
            minutes = len(face) / len(samples) * dur / 60
            cal["blink_rate"] = round(len(blinks) / minutes, 1) if minutes else None
            cal["blink_duration_ms"] = round(1000 * statistics.fmean(b[1] for b in blinks)) if blinks else None
            cal["calibrated"] = True
        cal = {k: (round(v, 4) if isinstance(v, float) else v) for k, v in cal.items()}
        self.db.x("INSERT INTO calibration (ts, step, data) VALUES (?, ?, ?)", (time.time(), step, json.dumps(cal)))
        with self.lock:
            self.engine.set_cal(cal)
            if step == 1:
                self.engine.distance = None
                self.engine.dist_raw.clear()
        self.db.save_baseline(self.engine.cal, f"calibration step {step}")
        await self.send({"type": "calibration", "step": step, "phase": "done", "progress": 1, "result": cal})
        await self.send_status(force=True)

    # ---------- websocket I/O ----------

    async def send(self, msg):
        if self.print_mode and msg.get("type") in ("event", "agent_text", "tool_call", "outcome", "agent_run", "calibration") \
                and not (msg.get("type") == "event" and msg.get("kind") == "dip"):
            print(json.dumps(msg, default=str)[:400], flush=True)
        ws = self.ws
        if ws is None:
            return
        try:
            await ws.send(json.dumps(msg, default=_json_default))
        except Exception:  # noqa: BLE001 - client went away
            pass

    async def send_status(self, force=False):
        s = {"camera_ok": self.camera_ok, "face_present": self.snapshot.get("face_present"),
             "paused": self.settings["tracking.paused"], "calibrated": self.snapshot.get("calibrated"),
             "fps": self.snapshot.get("fps"), "agent_busy": self.agent.busy,
             "frame_w": self.frame.shape[1] if self.frame is not None else None,
             "frame_h": self.frame.shape[0] if self.frame is not None else None, "demo_mode": self.settings["demo.enabled"],
             "agent_enabled": self.settings["agent.enabled"], "agent_available": self.agent.available(),
             "agent_provider": self.agent.provider(), "agent_clis": CLIS,
             "has_tts_key": bool(os.environ.get("CARTESIA_API_KEY")), "active_app": self.active, "last_action": self.last_action,
             "zen": self.zen.state(time.time()), "today": self.today, "local_vision": self.screen.state()}
        key = json.dumps(s, sort_keys=True, default=str)
        if force or key != self.last_status:
            self.last_status = key
            await self.send({"type": "status", **s})

    async def send_approvals(self):
        ap = self.db.approvals()
        await self.send({"type": "approvals", "tools": {
            n: {"tier": self.agent.tier(n) if T.CATALOG[n][3] or self.settings.get(f"tools.{n}.tier") else None,
                "approval": ap.get(n, "never_asked"), **T.meta(n)} for n in T.CATALOG}})

    async def send_preferences(self):
        await self.send({"type": "preferences", "rows": self.db.preferences(), "baseline": self.engine.cal})

    async def notice(self, text):
        await self.send({"type": "ui_request", "request_id": self.new_request_id(), "kind": "notice",
                         "payload": {"text": text}, "timeout_s": 0})

    def new_request_id(self):
        return uuid.uuid4().hex[:12]

    async def ui_request(self, kind, payload, timeout):
        """Send a UI request and wait for its ui_response. Returns the result or None (timeout / no UI)."""
        if self.ws is None:
            return None
        rid = self.new_request_id()
        fut = self.loop.create_future()
        self.futures[rid] = fut
        await self.send({"type": "ui_request", "request_id": rid, "kind": kind, "payload": payload, "timeout_s": timeout})
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            await self.send({"type": "ui_dismiss", "request_id": rid})
            return None
        finally:
            self.futures.pop(rid, None)

    async def tool_exec(self, name, args, timeout):
        if self.ws is None:
            return None
        rid = self.new_request_id()
        fut = self.loop.create_future()
        self.futures[rid] = fut
        await self.send({"type": "tool_exec", "request_id": rid, "name": name, "args": args})
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            return None
        finally:
            self.futures.pop(rid, None)

    async def handler(self, ws):
        path = ws.request.path if hasattr(ws, "request") else ws.path
        token = parse_qs(urlparse(path).query).get("token", [None])[0]
        if self.token and token != self.token:
            await ws.close(4401, "bad token")
            return
        if self.ws is not None:
            await self.ws.close(4000, "replaced by a new client")
            self.drop_requests()
        self.ws = ws
        await self.send({"type": "hello", "version": VERSION, "calibrated": bool(self.engine.cal.get("calibrated")),
                         "paused": self.settings["tracking.paused"], "settings": self.settings,
                         "triggers": {k: {"threshold": v[0], "sustain_s": v[1]} for k, v in TRIGGERS.items()}})
        await self.send_approvals()
        await self.send_preferences()
        await self.send_status(force=True)
        try:
            async for raw in ws:
                if isinstance(raw, bytes):
                    continue
                try:
                    await self.on_message(json.loads(raw))
                except Exception as e:  # noqa: BLE001
                    traceback.print_exc()
                    await self.send({"type": "error", "code": "bad_message", "message": str(e)[:300]})
        finally:
            if self.ws is ws:
                self.ws = None
                self.drop_requests()

    def drop_requests(self):
        """The client that would answer these is gone (its panels with it): resolve them as 'no UI'."""
        for fut in self.futures.values():
            if not fut.done():
                fut.set_result(None)

    async def on_message(self, m):
        t = m.get("type")
        if t in ("ui_response", "tool_result"):
            fut = self.futures.get(m.get("request_id"))
            if fut and not fut.done():
                fut.set_result(m.get("result") if t == "ui_response" else
                               {"ok": m.get("ok", False), "result": m.get("result"), "error": m.get("error")})
        elif t == "set_setting":
            await self.set_setting(m.get("key"), m.get("value"))
        elif t == "get_settings":
            await self.send({"type": "settings", "settings": self.settings})
        elif t == "get_approvals":
            await self.send_approvals()
        elif t == "set_tool_tier":
            await self.set_setting(f"tools.{m.get('tool')}.tier", m.get("tier"))
            await self.send_approvals()
        elif t == "history_request":
            await self.history_reply(m)
        elif t == "delete_preference":
            row = self.db.q("SELECT key FROM preferences WHERE id=?", (int(m.get("id")),))
            if row and row[0]["key"]:  # a learned rule the user removed: don't learn it again
                await self.set_setting("memory.suppressed", self.settings["memory.suppressed"] + [row[0]["key"]])
            self.db.x("DELETE FROM preferences WHERE id=?", (int(m.get("id")),))
            await self.send_preferences()
        elif t == "command":
            await self.command(m.get("name"), m.get("args") or {})
        else:
            await self.send({"type": "error", "code": "unknown_type", "message": f"unknown message type {t!r}"})

    async def set_setting(self, key, value):
        if not isinstance(key, str) or not validate_setting(key, value, T.CATALOG):
            return await self.send({"type": "error", "code": "bad_setting", "message": f"invalid setting {key}={value!r}"})
        self.db.set_setting(key, value)
        self.settings = self.db.settings()
        if key.startswith("privacy."):
            self.screen.wake.set()
        if key.startswith("advanced."):
            with self.lock:
                self.engine.adv.update(self._adv())
        await self.send({"type": "settings", "settings": self.settings})
        await self.send_status(force=True)

    async def command(self, name, args):
        if name in ("pause", "resume"):
            await self.set_setting("tracking.paused", name == "pause")
            self.log_event("system", None, None, {"event": name})
        elif name == "shutdown":
            self.stop.set()
            await self.speaker.stop()
            self.loop.call_later(0.3, self._finish)
        elif name == "calibrate":
            asyncio.create_task(self.calibrate(int(args.get("step", 0)), args))
        elif name == "reset_approvals":
            self.db.x("DELETE FROM approvals")
            await self.send_approvals()
        elif name == "reset_triggers":
            self.db.reset_settings("triggers.")
            self.settings = self.db.settings()
            await self.send({"type": "settings", "settings": self.settings})
        elif name == "seed_demo":
            n = demo.seed(self.db)
            self.log_event("system", None, n, {"event": "seed_demo"})
        elif name == "wipe_demo":
            demo.wipe(self.db)
            self.log_event("system", None, None, {"event": "wipe_demo"})
        elif name == "generate_summary":
            asyncio.create_task(self._summary(args.get("date")))
        elif name == "get_summary":
            r = self.db.q("SELECT date, text, stats FROM summaries WHERE date=?", (args.get("date"),))
            if r:
                await self.send({"type": "summary", "date": r[0]["date"], "text": r[0]["text"], "stats": json.loads(r[0]["stats"] or "{}")})
        elif name == "audio_control":
            self.speaker.control(args.get("action"))
        elif name == "zen":
            change = self.zen.set_manual(bool(args.get("on")), time.time())
            if change:
                await self.zen_changed(*change)
        elif name == "describe_screen":
            async def go():
                await self.screen.describe_now()
                await self.send_status(force=True)
            asyncio.create_task(go())
        elif name == "run_agent_now":
            if not self.agent.available():
                await self.send({"type": "error", "code": "agent_unavailable",
                                 "message": f"The {self.agent.provider()} CLI wasn't found. Install it or pick another provider in Settings."})
            elif not self.agent.busy:
                # fold in anything queued (e.g. a too_close waiting out the gap) so the manual run sees it
                queued = list(self.triggers.pending.values())
                self.triggers.pending.clear()
                asyncio.create_task(self.agent.run([{"id": "manual", "value": None, "fired_at": time.time()}] + queued))
        elif name == "check_shortcuts":
            ok, names = await asyncio.to_thread(S.focus_shortcuts_present)
            await self.send({"type": "shortcuts", "focus_ok": ok, "names": names})
        elif name == "doctor_eligibility":
            ok, why = self.agent.doctor_eligible()
            await self.send({"type": "doctor_eligibility", "eligible": ok, "detail": why})
        else:
            await self.send({"type": "error", "code": "unknown_command", "message": f"unknown command {name!r}"})

    async def _summary(self, date):
        try:
            await self.agent.daily_summary(date)
        except Exception as e:  # noqa: BLE001
            await self.send({"type": "error", "code": "summary_failed", "message": str(e)[:300]})

    async def history_reply(self, m):
        kind, frm, to = m.get("kind"), float(m.get("from") or 0), float(m.get("to") or time.time() + 1)
        limit = max(1, min(int(m.get("limit") or 500), 5000))
        if kind == "metrics":
            # downsample to <= limit rows across the range
            rows = self.db.q("SELECT ts, data, seeded FROM metrics_1hz WHERE ts >= ? AND ts < ? ORDER BY ts", (frm, to))
            step = max(1, len(rows) // limit)
            rows = [{"ts": r["ts"], **{k: v for k, v in json.loads(r["data"]).items()
                                       if k in HISTORY_KEYS}}
                    for r in rows[::step]]
        elif kind == "events":
            rows = self.db.q("SELECT * FROM events WHERE ts >= ? AND ts < ? ORDER BY ts DESC LIMIT ?", (frm, to, limit))
            for r in rows:
                r["details"] = json.loads(r["details"] or "null")
        elif kind == "runs":
            rows = self.db.q("SELECT * FROM agent_runs WHERE ts_start >= ? AND ts_start < ? ORDER BY id DESC LIMIT ?", (frm, to, limit))
            ids = [r["id"] for r in rows] or [-1]
            calls = self.db.q(f"""SELECT c.*, o.metric, o.before, o.after, o.verdict FROM tool_calls c
                                  LEFT JOIN outcomes o ON o.call_id = c.id
                                  WHERE c.run_id IN ({",".join("?" * len(ids))}) ORDER BY c.id""", ids)
            by_run = collections.defaultdict(list)
            for c in calls:
                c["args"] = json.loads(c["args"] or "{}")
                c["result"] = json.loads(c["result"]) if c["result"] else None
                by_run[c["run_id"]].append(c)
            for r in rows:
                r.pop("context", None)
                r["triggers"] = json.loads(r["triggers"] or "[]")
                r["tool_calls"] = by_run.get(r["id"], [])
        else:
            return await self.send({"type": "error", "code": "bad_history", "message": f"unknown history kind {kind!r}"})
        await self.send({"type": "history", "request_id": m.get("request_id"), "kind": kind, "rows": rows})

    async def stream_frames(self):
        last_ts = None
        while True:
            await asyncio.sleep(1 / 15)
            if self.ws is None:
                continue
            lm = self.landmarks
            if lm and lm.get("ts") != last_ts:
                last_ts = lm.get("ts")
                face = lm.get("face")
                msg = {"type": "landmarks", "ts": lm["ts"], "o": lm.get("o"), "face": [[round(p[0], 4), round(p[1], 4)] for p in face] if face else None,
                       "hands": [[[round(p[0], 4), round(p[1], 4)] for p in h] for h in lm.get("hands") or []]}
                if face:
                    msg["iris"] = {e: [round(face[c][0], 4), round(face[c][1], 4), round(abs(face[a][0] - face[b][0]) / 2, 4)]
                                   for e, c, a, b in (("r", 468, 469, 471), ("l", 473, 474, 476))}
                await self.send(msg)
            if self.settings["ui.show_camera_image"] and self.frame is not None and not self.settings["tracking.paused"]:
                jpg = cv2.imencode(".jpg", self.frame, [cv2.IMWRITE_JPEG_QUALITY, 70])[1].tobytes()
                try:
                    await self.ws.send(struct.pack("<d", time.time()) + jpg)
                except Exception:  # noqa: BLE001
                    pass

    async def print_loop(self):
        while True:
            await asyncio.sleep(0.5)
            s = self.snapshot
            f = lambda k, fmt="{}": "-" if s.get(k) is None else fmt.format(s[k])
            print(f"fps {f('fps')} face {int(bool(s.get('face_present')))} o {f('o')} blink/min {f('blink_rate')} "
                  f"inc% {f('incomplete_pct')} stare {f('current_stare_s')}/{f('longest_stare_s')}s perclos {f('perclos')} "
                  f"squint {f('squint_delta')}{'!' if s.get('squinting') else ''} dist {f('distance_cm')}cm "
                  f"yaw {f('yaw_deg')} pitch {f('pitch_deg')} gaze {'on' if s.get('gaze_on_screen') else 'off'} "
                  f"rub {int(bool(s.get('rubbing')))} yawns {f('yawn_count_5m')} room {f('room_luma')} "
                  f"screen {f('screen_luma')} break {f('since_real_break_s')}s cal {int(bool(s.get('calibrated')))}", flush=True)

    # ---------- main ----------

    def _finish(self):
        if not self.done.done():
            self.done.set_result(None)

    async def main(self):
        self.loop = asyncio.get_running_loop()
        self.done = self.loop.create_future()
        self.thread = threading.Thread(target=self.vision_thread, daemon=True)
        self.thread.start()
        tasks = [self.tick_5hz(), self.tick_1hz(), self.screen.loop(), self.agent.relearn()]
        if self.print_mode:
            tasks.append(self.print_loop())
        if self.port and not sys.stdin.isatty():
            # the app holds our stdin open; EOF means it died, so don't linger holding the camera and port
            def watch_stdin():
                while sys.stdin.buffer.read(1):
                    pass
                self.loop.call_soon_threadsafe(self._finish)
            threading.Thread(target=watch_stdin, daemon=True).start()
        if self.port:
            import websockets
            server = await websockets.serve(self.handler, "127.0.0.1", self.port, max_size=2 ** 22)
            print(f"eyeos: listening on 127.0.0.1:{self.port}", file=sys.stderr, flush=True)
            tasks.append(self.stream_frames())
        running = [asyncio.create_task(t) for t in tasks]
        await self.done
        self.stop.set()
        self.screen.stop()
        for t in running:
            t.cancel()


def _json_default(o):
    if hasattr(o, "item"):
        return o.item()
    return str(o)

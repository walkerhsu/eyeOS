"""Agent loop, approval gate, outcome evaluation and daily summary (SPEC §9)."""
import asyncio
import base64
import datetime as dt
import json
import statistics
import time
import traceback

import os
import shutil
from pathlib import Path

import claude_agent_sdk as sdk

from . import tools as T
from .metrics import verdict
from .tools import system as S
from .tts import page_text, selection_text, chunks

SYSTEM = """You are eyeOS, an eye-comfort assistant running on the user's Mac. You receive eye and
posture metrics computed from the webcam, context about what the user is doing, and
(sometimes) a webcam frame and a screenshot.

Goals, in order: protect the user's eyes and comfort; avoid breaking their focus;
learn what works for this person.

Rules:
- Before calling any tool, write 1-2 sentences explaining what you observe and why
  this action. Doing nothing is a valid choice - say why.
- Prefer the least disruptive effective action. Escalate only if earlier actions in
  recent_actions were neutral/worse.
- Do not repeat an action whose recent outcome was neutral/worse for the same trigger
  unless something changed.
- Respect every rule in preferences absolutely.
- If the user is in a call (category=call), only use silent tools.
- If unsure whether the user wants something disruptive, use ask_user with short options.
- When the user is typing in a burst, prefer to wait (no action) unless the signal is
  severe (eye_rub, drowsy).
- Never diagnose. Never use medical labels (no "dry eye", no "disease", no "condition").
  The webcam cannot verify far focus; a "break" only means the user looked away >= 20 s.
- Messages you write for the user are short, warm and natural, never nagging.
- A tool result starting with "blocked" or "declined" means do not retry that tool this run."""

CAVEATS = ["webcam cannot verify far focus; break = looked away >=20 s",
           "camera auto-exposure makes room_luma approximate",
           "distance is from iris size; uncalibrated values are rough"]

EXERCISES = {
    "palming": [("Rub your palms together until they feel warm.", 0.15),
                ("Close your eyes and gently cup your palms over them. No pressure on the eyes.", 0.15),
                ("Breathe slowly. Let the darkness relax your eyes.", 0.55),
                ("Slowly lower your hands and open your eyes.", 0.15)],
    "focus_shift": [("Hold a finger about 25 centimeters from your face and focus on it.", 0.2),
                    ("Now look past it at something far away.", 0.2),
                    ("Back to your finger.", 0.2),
                    ("And far away again. Let your eyes relax.", 0.2),
                    ("Blink a few times. Nice work.", 0.2)],
    "deliberate_blink": [("Let's do slow, complete blinks.", 0.15),
                         ("Close your eyes fully, squeeze gently, and pause.", 0.3),
                         ("Open slowly. Again: close fully, pause, open.", 0.3),
                         ("Keep blinking fully and slowly at your own pace.", 0.25)],
}

DOCTOR_TEXT = ("Over the past week your eyes have shown signs often linked to eye strain or dryness ({evidence}). "
               "eyeOS can't diagnose anything, but it might be worth mentioning to an eye doctor or optometrist.")


# The app's PATH is minimal, so look in the usual install spots too. Uses the user's `claude` login,
# or ANTHROPIC_API_KEY when set.
CLAUDE_CLI = shutil.which("claude", path=os.environ.get("PATH", "") + os.pathsep + os.pathsep.join(
    str(Path(p).expanduser()) for p in ("~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin")))


def _now_ctx():
    return S.time_of_day()


class Agent:
    def __init__(self, app):
        self.app = app
        self.db = app.db
        self.busy = False
        self.latencies = []
        self.pending_suggestions = []  # {call_id, tool, ts}
        self.state = {"focus_on": False, "increase_contrast": False}
        self.run_text = {}  # run_id -> latest rationale, shown as the approval reason

    # ---------- run ----------

    async def run(self, triggers, run_kind="event"):
        self.busy = True
        app, db = self.app, self.db
        s = app.settings
        t0 = time.time()
        run_id = db.x("INSERT INTO agent_runs (ts_start, status, triggers) VALUES (?, 'started', ?)",
                      (t0, json.dumps(triggers)))
        for tr in triggers:
            if tr.get("event_id"):
                db.x("UPDATE events SET run_id=? WHERE id=?", (run_id, tr["event_id"]))
        await app.send({"type": "agent_run", "run_id": run_id, "ts": t0, "phase": "started", "triggers": triggers})
        thinking, texts, usage_in, usage_out, images_sent = [], [], 0, 0, 0
        model = s["agent.model"]
        if len(self.latencies) >= 3 and statistics.median(self.latencies[-5:]) > 6 and model == "claude-sonnet-5-5":
            model = "claude-haiku-5-5"  # R6: fall back when Sonnet is too slow for the "instant" reaction
        try:
            ctx = await self.context(triggers)
            content = []
            heartbeat_only = all(t["id"] == "heartbeat" for t in triggers)
            if s["agent.send_images"] and not heartbeat_only:
                cam = app.webcam_jpeg(512)
                scr = await asyncio.to_thread(S.screenshot_jpeg, 1280)
                for label, img in (("webcam", cam), ("screen", scr)):
                    if img:
                        content += [{"type": "text", "text": label},
                                    {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                                 "data": base64.b64encode(img).decode()}}]
                        images_sent += 1
            content.append({"type": "text", "text": json.dumps(ctx, default=str)})
            db.x("UPDATE agent_runs SET context=?, images_sent=?, model=? WHERE id=?",
                 (json.dumps(ctx, default=str), images_sent, model, run_id))
            for attempt in (0, 1):
                acted = []
                try:
                    async for m in self._query(model, content, self._mcp(run_id, triggers, acted), s["agent.max_tool_iterations"]):
                        if isinstance(m, sdk.AssistantMessage):
                            for b in m.content:
                                if isinstance(b, sdk.ThinkingBlock) and b.thinking:
                                    thinking.append(b.thinking)
                                    await app.send({"type": "agent_thinking", "run_id": run_id, "text": b.thinking})
                                elif isinstance(b, sdk.TextBlock) and b.text:
                                    texts.append(b.text)
                                    self.run_text[run_id] = b.text
                                    await app.send({"type": "agent_text", "run_id": run_id, "text": b.text})
                        elif isinstance(m, sdk.ResultMessage):
                            u = m.usage or {}
                            usage_in += (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)
                            usage_out += u.get("output_tokens") or 0
                            if m.is_error and m.subtype != "error_max_turns":
                                raise RuntimeError(m.result or m.subtype)
                    break
                except Exception:  # noqa: BLE001
                    if attempt or acted:  # retry once (§9.1.7), never after a tool already ran
                        raise
                    await asyncio.sleep(3)
            status, err = "finished", None
        except Exception as e:  # noqa: BLE001 - every failure is logged and streamed, never crashes the loop
            status, err = "error", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        finally:
            self.busy = False
        self.latencies.append(time.time() - t0)
        db.x("UPDATE agent_runs SET ts_end=?, status=?, thinking=?, text=?, input_tokens=?, output_tokens=?, error=? WHERE id=?",
             (time.time(), status, "\n\n".join(thinking), "\n\n".join(texts), usage_in, usage_out, err, run_id))
        msg = {"type": "agent_run", "run_id": run_id, "ts": time.time(), "phase": status, "triggers": triggers,
               "input_tokens": usage_in, "output_tokens": usage_out, "latency_s": round(time.time() - t0, 2)}
        if err:
            msg["error"] = err
        await app.send(msg)

    def _options(self, model, system, max_turns, mcp=None):
        names = [f"mcp__eyeos__{n}" for n in T.CATALOG] if mcp else []
        return sdk.ClaudeAgentOptions(
            model=model, system_prompt=system, max_turns=max_turns, tools=[], allowed_tools=names,
            mcp_servers={"eyeos": mcp} if mcp else {}, setting_sources=[], cli_path=CLAUDE_CLI,
            thinking={"type": "adaptive", "display": "summarized"}, effort="low", cwd=str(Path.home()))

    async def _query(self, model, content, mcp, max_turns):
        async def prompt():
            yield {"type": "user", "message": {"role": "user", "content": content}, "parent_tool_use_id": None}
        async for m in sdk.query(prompt=prompt(), options=self._options(model, SYSTEM, max_turns + 1, mcp)):
            yield m

    def _mcp(self, run_id, triggers, acted):
        """One in-process MCP server per run; every call goes through the gate (§9.2)."""
        def make(name):
            async def handler(args):
                acted.append(name)
                out = await self.call_tool(run_id, None, name, args, triggers)
                if isinstance(out, list):  # screenshot: Anthropic image blocks -> MCP image content
                    return {"content": [{"type": "image", "data": b["source"]["data"], "mimeType": "image/jpeg"} for b in out]}
                return {"content": [{"type": "text", "text": out if isinstance(out, str) else json.dumps(out, default=str)[:20000]}],
                        "is_error": isinstance(out, dict) and "error" in out}
            return sdk.tool(name, T.CATALOG[name][0], T.CATALOG[name][1])(handler)
        return sdk.create_sdk_mcp_server("eyeos", tools=[make(n) for n in T.CATALOG])

    async def complete(self, system, text, model=None):
        """Single-shot text completion (no tools), e.g. the daily summary."""
        out = []
        async for m in sdk.query(prompt=text, options=self._options(model or self.app.settings["agent.model"], system, 1)):
            if isinstance(m, sdk.AssistantMessage):
                out += [b.text for b in m.content if isinstance(b, sdk.TextBlock)]
            elif isinstance(m, sdk.ResultMessage) and m.is_error:
                raise RuntimeError(m.result or m.subtype)
        return " ".join(out).strip()

    # ---------- context ----------

    async def context(self, triggers):
        app, db = self.app, self.db
        snap = app.snapshot
        active = app.active
        recent = db.q("""SELECT c.id, c.ts, c.name AS tool, c.args, c.status, o.metric, o.before, o.after, o.verdict
                         FROM tool_calls c LEFT JOIN outcomes o ON o.call_id = c.id
                         ORDER BY c.id DESC LIMIT 10""")
        for r in recent:
            r["args"] = json.loads(r["args"] or "{}")
            meta = T.CATALOG.get(r["tool"])
            if r["verdict"]:
                r["outcome"] = {"metric": r.pop("metric"), "before": r.pop("before"), "after": r.pop("after"),
                                "verdict": r.pop("verdict")}
            else:
                for k in ("metric", "before", "after", "verdict"):
                    r.pop(k)
                r["outcome"] = "pending" if meta and meta[6] and r["status"] == "done" else None
        approvals = db.approvals()
        day0 = dt.datetime.combine(dt.date.today(), dt.time()).timestamp()
        bl = app.engine.cal
        return {
            "triggers": [{"id": t["id"], "value": t["value"],
                          "fired_at": dt.datetime.fromtimestamp(t["fired_at"]).astimezone().isoformat(timespec="seconds")}
                         for t in triggers],
            "now": _now_ctx(),
            "snapshot": snap,
            "trend_10m": app.trend_10m(),
            "baseline": {"blink_rate": bl.get("blink_rate"), "blink_duration_ms": bl.get("blink_duration_ms"),
                         "ear_open": bl.get("ear_open"), "squint_score": bl.get("squint_score"),
                         "distance_cm": bl.get("distance_cm"), "calibrated": bl.get("calibrated")},
            "active_app": active,
            "system_state": {"dark_mode": snap.get("dark_mode"), "focus_on": self.state["focus_on"],
                             "audio_playing": app.speaker.busy(), "increase_contrast": self.state["increase_contrast"]},
            "typing": app.typing(),
            "preferences": [{"id": p["id"], "rule": p["rule"], "app": p["app"]} for p in db.preferences()],
            "recent_actions": list(reversed(recent)),
            "tool_approval_states": {n: approvals.get(n, "never_asked") for n, v in T.CATALOG.items()
                                     if v[2] == "action" or n in T.FIRST_USE_READS},
            "today": {"screen_time_min": round((snap.get("screen_time_today_s") or 0) / 60),
                      "breaks": db.q("SELECT COUNT(*) n FROM events WHERE kind='break' AND ts>=?", (day0,))[0]["n"],
                      "interventions": db.q("SELECT COUNT(*) n FROM tool_calls WHERE status='done' AND ts>=?", (day0,))[0]["n"]},
            "pending_suggestions": [{"tool": p["tool"], "seconds_ago": round(time.time() - p["ts"])}
                                    for p in self.pending_suggestions],
            "caveats": CAVEATS,
        }

    # ---------- gate (§9.2) ----------

    def tier(self, name):
        return self.app.settings.get(f"tools.{name}.tier") or T.CATALOG[name][3]

    def quiet(self):
        a = self.app.active
        if a.get("category") == "call":
            return a.get("name") or "a call"
        for q in self.app.settings["quiet_apps"]:
            if q and (q == a.get("bundle_id") or q.lower() in (a.get("window_title") or "").lower()):
                return a.get("name") or q
        return None

    async def call_tool(self, run_id, call_id, name, args, triggers):
        app, db = self.app, self.db
        meta = T.meta(name) if name in T.CATALOG else {"kind": None, "tier": None, "executor": None, "ui": False, "target": None}
        tier = self.tier(name) if name in T.CATALOG else None
        approval_state = db.approvals().get(name, "never_asked")
        row = db.x("INSERT INTO tool_calls (run_id, ts, name, args, status, tier, approval) VALUES (?, ?, ?, ?, 'requested', ?, ?)",
                   (run_id, time.time(), name, json.dumps(args), tier, approval_state))

        async def status(st, result=None):
            db.x("UPDATE tool_calls SET status=?, result=? WHERE id=?", (st, json.dumps(result, default=str) if result is not None else None, row))
            await app.send({"type": "tool_call", "run_id": run_id, "call_id": row, "name": name, "args": args,
                            "status": st, "result": result, "tier": tier, "executor": meta["executor"]})

        await status("requested")
        err = T.validate(name, args)
        if err:
            await status("failed", err)
            return {"error": err}
        if tier == "blocked":
            await status("blocked_tier", "blocked by user setting")
            return "blocked: the user has blocked this tool"
        q = self.quiet()
        if q and meta["ui"]:
            await status("blocked_suppressed", f"user is in {q}")
            return f"blocked: user is on a call or in a quiet app ({q}); only silent tools are allowed"
        hard = self.hard_rules(name, triggers)
        if hard:
            await status("blocked_tier", hard)
            return f"blocked: {hard}"

        # approval
        needs_first_use = (meta["kind"] == "action" or name in T.FIRST_USE_READS) and approval_state == "never_asked"
        needs_each = tier == "ask" or (meta["kind"] == "action" and approval_state == "declined")
        if needs_first_use or needs_each:
            await status("awaiting_approval")
            reason = " ".join(t["id"] for t in triggers)
            res = await app.ui_request("approval", {
                "tool": name, "args": args, "reason": self.run_text.get(run_id) or reason,
                "question": f"Allow eyeOS to use {name.replace('_', ' ')}?",
                "effect": T.CATALOG[name][0].split(". ")[0],
                "first_use": needs_first_use}, 60)
            approved = bool(res and res.get("approved"))
            if needs_first_use and res is not None:
                db.set_approval(name, "approved" if approved else "declined")
                if not approved:
                    db.add_preference(f"User declined {name} on {dt.date.today()} (context: {reason})", source="auto_decline")
                await app.send_approvals()
            db.x("UPDATE tool_calls SET approval=? WHERE id=?", ("approved" if approved else "declined" if res else "timeout", row))
            if not approved:
                await status("declined", "declined by user" if res else "no answer (60 s)")
                return "declined by user" if res else "declined: no answer within 60 s"
            await status("approved")

        await status("executing")
        try:
            ok, result = await self.execute(name, args, row)
        except Exception as e:  # noqa: BLE001
            ok, result = False, f"{type(e).__name__}: {e}"
        await status("done" if ok else "failed", result)
        if ok and meta["kind"] == "action":
            app.last_action = {"name": name, "ts": time.time()}
            if meta["target"] or name == "start_guided_eye_exercise":
                asyncio.create_task(self.evaluate_outcome(row, name, meta["target"], time.time()))
        return result if ok else {"error": result}

    def hard_rules(self, name, triggers):
        db = self.db
        if name == "suggest_seeing_eye_doctor":
            ok, why = self.doctor_eligible()
            if not ok:
                return f"not eligible: {why}"
        if T.CATALOG[name][2] == "action":
            n = db.q("SELECT COUNT(*) n FROM tool_calls WHERE name=? AND status='done' AND ts>?", (name, time.time() - 3600))[0]["n"]
            if n >= 3:
                return f"{name} already used 3 times in the last hour"
        if name == "update_baseline":
            recent = db.q("SELECT COUNT(*) n FROM events WHERE kind='trigger' AND trigger_id NOT IN ('heartbeat','break_taken') AND ts>?",
                          (time.time() - 600,))[0]["n"]
            if recent:
                return "cannot update the baseline within 10 min of an active trigger"
        return None

    def doctor_eligible(self):
        db = self.db
        if db.q("SELECT 1 FROM tool_calls WHERE name='suggest_seeing_eye_doctor' AND status='done' AND ts>?",
                (time.time() - 7 * 86400,)):
            return False, "already suggested in the last 7 days"
        days = db.q("""SELECT date(ts, 'unixepoch', 'localtime') d,
                              MAX(json_extract(data, '$.screen_time_today_s')) st,
                              AVG(json_extract(data, '$.blink_rate')) br,
                              AVG(json_extract(data, '$.incomplete_pct')) ip
                       FROM metrics_1hz WHERE ts > ? GROUP BY d""", (time.time() - 7 * 86400,))
        rubs = {r["d"]: r["n"] for r in db.q("""SELECT date(ts, 'unixepoch', 'localtime') d, COUNT(*) n FROM events
                                                WHERE kind='rub' AND ts > ? GROUP BY d""", (time.time() - 7 * 86400,))}
        flagged = [d for d in days if (d["st"] or 0) >= 3600 and
                   ((d["br"] is not None and d["br"] < 8) or (d["ip"] or 0) > 0.4 or rubs.get(d["d"], 0) >= 5)]
        if len(flagged) < 3:
            return False, f"only {len(flagged)} of the last 7 days show the pattern (needs 3)"
        return True, flagged

    # ---------- executors ----------

    async def execute(self, name, args, call_id):
        app = self.app
        a = args
        if name == "set_dark_mode":
            ok, r = await S.arun(S.set_dark_mode, a["enabled"])
            if ok:
                await app.notice("Dark mode " + ("on" if a["enabled"] else "off"))
                app.refresh_screen_soon()
            return ok, r
        if name == "set_increase_contrast":
            ok, r = await S.arun(S.set_increase_contrast, a["enabled"])
            if ok:
                self.state["increase_contrast"] = a["enabled"]
                await app.notice("Increase contrast " + ("on" if a["enabled"] else "off"))
            return ok, r
        if name == "set_reduce_transparency":
            return await S.arun(S.set_reduce_transparency, a["enabled"])
        if name == "set_reduce_motion":
            return await S.arun(S.set_reduce_motion, a["enabled"])
        if name == "set_cursor_size":
            return await S.arun(S.set_cursor_size, a["size"])
        if name == "set_focus_mode":
            ok, r = await S.arun(S.set_focus, a["enabled"])
            if ok:
                self.state["focus_on"] = a["enabled"]
                if a["enabled"] and a.get("minutes"):
                    asyncio.create_task(self._focus_off_later(a["minutes"] * 60))
                    r += f"; will turn off in {a['minutes']} min"
            return ok, r
        if name == "remind_to_blink":
            res = await app.ui_request("blink_pulse", {"count": a["count"], "intensity": a["intensity"]}, 10)
            return res is not None, "pulse shown" if res is not None else "UI did not respond"
        if name == "suggest_look_out_window":
            asyncio.create_task(app.ui_request("look_away_card", {"message": a["message"], "duration_s": 20}, 60))
            self.pending_suggestions.append({"call_id": call_id, "tool": name, "ts": time.time()})
            return True, "card shown; the camera will verify the break"
        if name == "start_guided_eye_exercise":
            steps = [{"text": t, "seconds": max(3, round(f * a["duration_s"]))} for t, f in EXERCISES[a["type"]]]
            asyncio.create_task(app.ui_request("exercise", {"type": a["type"], "duration_s": a["duration_s"], "steps": steps},
                                               a["duration_s"] + 30))
            asyncio.create_task(self._narrate(steps))
            self.pending_suggestions.append({"call_id": call_id, "tool": name, "ts": time.time()})
            return True, f"{a['type']} exercise started ({a['duration_s']} s)"
        if name == "play_ambient_cue":
            res = await app.tool_exec(name, a, 10)
            return (res or {}).get("ok", False), (res or {}).get("result") or (res or {}).get("error") or "UI did not respond"
        if name == "switch_to_audio":
            return await self._audio(a["source"])
        if name == "stop_audio":
            await app.speaker.stop()
            return True, "stopped"
        if name == "get_active_app":
            return True, app.active
        if name == "get_time_of_day":
            return True, _now_ctx()
        if name == "get_screenshot":
            img = await asyncio.to_thread(S.screenshot_jpeg, 1280)
            if not img:
                return False, "screenshot unavailable (Screen Recording permission?)"
            return True, [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                       "data": base64.b64encode(img).decode()}}]
        if name == "ask_user":
            res = await app.ui_request("ask_user", {"question": a["question"], "options": a["options"],
                                                    "allow_free_text": a.get("allow_free_text", False)}, 60)
            return True, res or {"choice": None, "note": "no answer within 60 s"}
        if name == "save_user_preference":
            pid = self.db.add_preference(a["rule"], a.get("app"), "agent")
            await app.send_preferences()
            return True, {"saved": pid}
        if name == "get_user_baseline":
            return True, app.engine.cal
        if name == "update_baseline":
            return app.update_baseline(a["reason"])
        if name == "generate_daily_summary":
            return True, await self.daily_summary(a.get("date"))
        if name == "enlarge_active_window":
            return await S.arun(S.enlarge_active_window, a["fraction"])
        if name == "move_window_closer_to_center":
            return await S.arun(S.move_window_closer_to_center)
        if name == "apply_reading_mode":
            return await S.arun(S.apply_reading_mode, app.active.get("bundle_id"))
        if name == "get_typing_activity":
            return True, app.typing()
        if name == "get_calendar_events":
            res = await app.tool_exec(name, a, 10)
            return (res or {}).get("ok", False), (res or {}).get("result") or (res or {}).get("error") or "UI did not respond"
        if name == "suggest_seeing_eye_doctor":
            msg = DOCTOR_TEXT.format(evidence=a["evidence"])
            asyncio.create_task(app.ui_request("doctor_card", {"message": msg, "evidence": a["evidence"]}, 600))
            return True, "card shown"
        return False, f"no executor for {name}"

    async def _focus_off_later(self, seconds):
        await asyncio.sleep(seconds)
        ok, _ = await S.arun(S.set_focus, False)
        if ok:
            self.state["focus_on"] = False

    async def _narrate(self, steps):
        if not os.environ.get("CARTESIA_API_KEY"):
            return  # no voice without a Cartesia key; the overlay still shows the steps
        try:
            for st in steps:
                t = time.time()
                await self.app.speaker.speak([st["text"]])
                await self.app.speaker.task
                await asyncio.sleep(max(0, st["seconds"] - (time.time() - t)))
        except Exception:  # noqa: BLE001 - narration is optional; the overlay still runs
            traceback.print_exc()

    async def _audio(self, source):
        app = self.app
        if source == "browser_tab":
            text, err = await asyncio.to_thread(page_text, app.active.get("bundle_id"))
        else:
            text, err = await asyncio.to_thread(selection_text), None
        if not text:
            return False, err or "no text found"
        parts = chunks(text)
        rid = app.new_request_id()

        async def done():
            await app.send({"type": "ui_dismiss", "request_id": rid})
        await app.send({"type": "ui_request", "request_id": rid, "kind": "audio_panel",
                        "payload": {"title": app.active.get("window_title") or "Selected text", "source": source},
                        "timeout_s": 0})
        await app.speaker.speak(parts, on_done=done)
        return True, f"reading {len(text)} characters aloud in {len(parts)} chunks"

    # ---------- outcomes (§9.7) ----------

    async def evaluate_outcome(self, call_id, tool, metric, t_call):
        await asyncio.sleep(195)
        app = self.app
        if tool in ("suggest_look_out_window", "start_guided_eye_exercise"):
            metric = "since_real_break_s"
            brk = app.engine.last_break_end
            # a real break that started within 2 min ends (and is recorded) by the time we evaluate
            v = "confirmed_break" if brk and brk > t_call else "no_break"
            before = after = None
            self.pending_suggestions = [p for p in self.pending_suggestions if p["call_id"] != call_id]
        else:
            hist = list(app.history)

            def val(snap):
                x = snap.get(metric) if metric != "gaze_on_screen_pct" else (1.0 if snap.get("gaze_on_screen") else 0.0)
                if metric == "yaw_deg" and x is not None:
                    x = abs(x)
                return x
            pre = [val(h) for h in hist if t_call - 120 <= h["ts"] < t_call and h.get("face_present")]
            post_all = [h for h in hist if t_call + 15 <= h["ts"] <= t_call + 195]
            post = [val(h) for h in post_all if h.get("face_present")]
            pre, post = [x for x in pre if x is not None], [x for x in post if x is not None]
            before = statistics.fmean(pre) if pre else None
            after = statistics.fmean(post) if post else None
            frac = (sum(1 for h in post_all if h.get("face_present")) / len(post_all)) if post_all else 0
            v = verdict(metric, before, after, frac)
        oid = self.db.x("INSERT INTO outcomes (call_id, ts, metric, before, after, verdict) VALUES (?, ?, ?, ?, ?, ?)",
                        (call_id, time.time(), metric, before, after, v))
        await app.send({"type": "outcome", "action_id": oid, "call_id": call_id, "tool": tool, "metric": metric,
                        "before": None if before is None else round(before, 3),
                        "after": None if after is None else round(after, 3), "verdict": v})

    # ---------- daily summary (§9.9) ----------

    def summary_stats(self, date):
        db = self.db
        d0 = dt.datetime.fromisoformat(date).timestamp()
        d1 = d0 + 86400
        rng = (d0, d1)
        cats = db.q("""SELECT app_category cat, COUNT(*) n,
                              ROUND(AVG(json_extract(data, '$.blink_rate')), 1) blink_rate,
                              ROUND(AVG(json_extract(data, '$.incomplete_pct')), 2) incomplete_pct,
                              ROUND(AVG(json_extract(data, '$.perclos')), 3) perclos,
                              ROUND(AVG(json_extract(data, '$.distance_cm')), 1) distance_cm
                       FROM metrics_1hz WHERE ts >= ? AND ts < ? GROUP BY app_category""", rng)
        top = db.q("""SELECT MAX(json_extract(data, '$.screen_time_today_s')) st,
                             MAX(json_extract(data, '$.longest_stare_s')) ls FROM metrics_1hz WHERE ts >= ? AND ts < ?""", rng)[0]
        breaks = db.q("SELECT COUNT(*) n FROM events WHERE kind='break' AND ts >= ? AND ts < ?", rng)[0]["n"]
        tools = db.q("""SELECT c.name, COUNT(*) uses,
                               SUM(o.verdict IN ('improved','confirmed_break')) improved,
                               SUM(o.verdict = 'neutral') neutral, SUM(o.verdict IN ('worse','no_break')) worse
                        FROM tool_calls c LEFT JOIN outcomes o ON o.call_id = c.id
                        WHERE c.status='done' AND c.ts >= ? AND c.ts < ? GROUP BY c.name""", rng)
        eff = [t for t in tools if t["uses"] >= 2 and t["improved"]]
        best = max(eff, key=lambda t: t["improved"] / t["uses"])["name"] if eff else None
        return {"date": date, "screen_time_min": round((top["st"] or 0) / 60), "longest_stare_s": top["ls"],
                "breaks": breaks, "by_category": cats, "interventions": tools, "most_effective_tool": best}

    async def daily_summary(self, date=None):
        date = date or dt.date.today().isoformat()
        stats = self.summary_stats(date)
        text = await self.complete(
            "You write eyeOS's daily eye-comfort summary. Write 3-5 friendly sentences in the style: "
            "\"You averaged 7 blinks/min while coding, 14 while reading; the font bump helped most.\" "
            "Use only the numbers given. Never diagnose or use medical labels. If there is little data, say so briefly.",
            json.dumps(stats))
        self.db.x("INSERT OR REPLACE INTO summaries (date, ts, text, stats) VALUES (?, ?, ?, ?)",
                  (date, time.time(), text, json.dumps(stats)))
        await self.app.send({"type": "summary", "date": date, "text": text, "stats": stats})
        return text

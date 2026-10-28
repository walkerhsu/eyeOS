"""Tool catalogue (SPEC §9.5): Anthropic tool schemas + gating metadata."""


def _obj(props=None, required=()):
    return {"type": "object", "properties": props or {}, "required": list(required), "additionalProperties": False}


B = {"type": "boolean"}

# name: (description, schema, kind, default tier, ui, exec, target metric)
CATALOG = {
    "set_dark_mode": (
        "Turn macOS dark mode on or off. Silent, low disruption. Good when the room is dark and the screen is bright, "
        "or the user squints at a bright screen at night.",
        _obj({"enabled": B}, ["enabled"]), "action", "ask", False, "py", "squint_delta"),
    "set_increase_contrast": (
        "Toggle the macOS Increase Contrast accessibility setting. Silent, low disruption. For sustained squinting at low-contrast UI.",
        _obj({"enabled": B}, ["enabled"]), "action", "ask", False, "py", "squint_delta"),
    "set_reduce_transparency": (
        "Toggle macOS Reduce Transparency. Silent, very low disruption.",
        _obj({"enabled": B}, ["enabled"]), "action", "auto", False, "py", None),
    "set_reduce_motion": (
        "Toggle macOS Reduce Motion. Silent, very low disruption.",
        _obj({"enabled": B}, ["enabled"]), "action", "auto", False, "py", None),
    "set_focus_mode": (
        "Turn Do Not Disturb (Focus) on or off, optionally for N minutes. Silent. Use to protect a rest or an exercise "
        "from notifications, or to reduce visual interruptions.",
        _obj({"enabled": B, "minutes": {"type": "integer", "minimum": 1, "maximum": 240}}, ["enabled"]),
        "action", "auto", False, "py", "blink_rate"),
    "remind_to_blink": (
        "Show a soft glow pulsing at the screen edges `count` times as a subliminal blink cue. Subtle, the least "
        "disruptive visual nudge. Good first response to low blink rate or a long stare.",
        _obj({"count": {"type": "integer", "minimum": 1, "maximum": 5},
              "intensity": {"type": "number", "minimum": 0, "maximum": 1}}, ["count", "intensity"]),
        "action", "auto", True, "swift", "blink_rate"),
    "suggest_look_out_window": (
        "Show a small non-modal card for 20 s asking the user to look at something far away (20-20-20 rule). Write a "
        "short, warm, natural message. Medium disruption. The camera verifies whether a real break happened.",
        _obj({"message": {"type": "string", "maxLength": 200}}, ["message"]),
        "action", "auto", True, "swift", "since_real_break_s"),
    "start_guided_eye_exercise": (
        "Start a full-screen guided eye exercise with voice narration. The camera checks it live (counts full vs half "
        "blinks, catches peeking, scores eye tracking) and the result comes back as the call's result. palming = cover "
        "eyes with warm palms (strain; the habit coach already offers it for eye rubs); focus_shift = near/far focusing (long near work); deliberate_blink = "
        "slow full blinks (incomplete blinks, dryness); gaze_trace = follow a moving dot with the eyes (long fixed "
        "stares). High disruption; use when gentler nudges failed.",
        _obj({"type": {"type": "string", "enum": ["palming", "focus_shift", "deliberate_blink", "gaze_trace"]},
              "duration_s": {"type": "integer", "minimum": 20, "maximum": 120}}, ["type", "duration_s"]),
        "action", "ask", True, "swift", "blink_rate"),
    "play_ambient_cue": (
        "Play a short soft sound (chime, rain or bowl) as an audible blink/rest cue. Low-medium disruption (audio).",
        _obj({"sound": {"type": "string", "enum": ["chime", "rain", "bowl"]}}, ["sound"]),
        "action", "auto", True, "swift", "blink_rate"),
    "switch_to_audio": (
        "Read the current browser tab (Safari/Chrome) or the selected text aloud so the user can rest their eyes. "
        "Medium disruption. Best for long reading with squinting or strain. Ask first if unsure.",
        _obj({"source": {"type": "string", "enum": ["browser_tab", "selection"]}}, ["source"]),
        "action", "ask", True, "py", "gaze_on_screen_pct"),
    "stop_audio": ("Stop any audio eyeOS is playing.", _obj(), "action", "auto", False, "py", None),
    "get_active_app": ("Get the frontmost app name and category, plus its window title when there's no screen description.", _obj(), "read", None, False, "py", None),
    "get_time_of_day": ("Get local time, weekday and whether it is night.", _obj(), "read", None, False, "py", None),
    "describe_screen": (
        "Refresh the on-device description of what is on screen (activity, content type, text size, background). A local "
        "model looks at the screen; you only get its text description, never pixels.",
        _obj(), "read", None, False, "py", None),
    "ask_user": (
        "Ask the user a short question in a small floating panel with up to 4 options. Options are button labels: "
        "1-3 words each (e.g. 'Start', 'In 5 min', 'Skip today'); put any detail in the question. A 'Not now' button "
        "is always shown, so don't include one. Times out after 60 s (returns null). Use when unsure whether "
        "something disruptive is welcome.",
        _obj({"question": {"type": "string", "maxLength": 200},
              "options": {"type": "array", "items": {"type": "string", "maxLength": 20}, "maxItems": 4},
              "allow_free_text": B}, ["question", "options"]),
        "read", None, True, "swift", None),
    "save_user_preference": (
        "Remember a rule about this user (e.g. 'Never change dark mode while Figma is open'). It is shown in every future run.",
        _obj({"rule": {"type": "string", "maxLength": 300}, "app": {"type": "string"}}, ["rule"]),
        "memory", None, False, "py", None),
    "get_user_baseline": ("Get the user's calibrated baseline metrics.", _obj(), "memory", None, False, "py", None),
    "update_baseline": (
        "Recompute the baseline from the last 30 min of normal, untriggered data. Only when the user's normal has clearly changed.",
        _obj({"reason": {"type": "string"}}, ["reason"]), "memory", "ask", False, "py", None),
    "generate_daily_summary": ("Generate the friendly daily summary for a date (YYYY-MM-DD, default today).",
                               _obj({"date": {"type": "string"}}), "memory", None, False, "py", None),
    # nice-to-have
    "set_cursor_size": ("Make the mouse pointer larger (size 1.0-4.0). Silent.",
                        _obj({"size": {"type": "number", "minimum": 1, "maximum": 4}}, ["size"]),
                        "action", "ask", False, "py", "squint_delta"),
    "enlarge_active_window": (
        "Resize the front window to a fraction (0.6-1.0) of the screen, centered. Low-medium disruption. For squinting "
        "at a small window or leaning in.",
        _obj({"fraction": {"type": "number", "minimum": 0.6, "maximum": 1.0}}, ["fraction"]),
        "action", "ask", False, "py", "distance_cm"),
    "move_window_closer_to_center": ("Center the front window without resizing. For sustained head turn (large |yaw|).",
                                     _obj(), "action", "ask", False, "py", "yaw_deg"),
    "apply_reading_mode": ("Switch the browser page to a larger, high-contrast reading layout (Safari Reader / Chrome CSS).",
                           _obj(), "action", "ask", False, "py", "squint_delta"),
    "get_typing_activity": ("Seconds since the last key press and whether the user is in a typing burst.",
                            _obj(), "read", None, False, "py", None),
    "get_calendar_events": ("Get calendar events in the next N hours (title, start, end, busy).",
                            _obj({"hours_ahead": {"type": "integer", "minimum": 1, "maximum": 12}}, ["hours_ahead"]),
                            "read", None, False, "swift", None),
    "set_display_brightness": (
        "Set the built-in display brightness (0.05-1.0; the current level is in system_state.display_brightness). Silent. "
        "Lower it when the screen is much brighter than the room (dark room, light background); raise it slightly when "
        "squinting at a dim screen in a bright room. Code limits each change to 0.3.",
        _obj({"level": {"type": "number", "minimum": 0.05, "maximum": 1.0}}, ["level"]),
        "action", "ask", False, "py", "squint_delta"),
    "set_blink_blur": (
        "Turn blink blur on or off and set its strength (0.2-1). While on, the screen slowly softens after a stare "
        "without blinking and a blink clears it: an automatic blink cue that never interrupts. The current state is in "
        "system_state.blink_blur; its outcome is measured on blink_rate, so recent_actions show whether it helps this "
        "user. Turn it on or up for a persistent low blink rate or long stares that gentler cues didn't fix; turn it "
        "down or off when it isn't raising blink_rate or the user finds it distracting.",
        _obj({"enabled": B, "strength": {"type": "number", "minimum": 0.2, "maximum": 1.0}}, ["enabled"]),
        "action", "ask", False, "py", "blink_rate"),
    "set_text_zoom": (
        "Make text bigger or smaller in the front app (Cmd +/-/0: browsers, editors, Mail, Notes). Low disruption. For "
        "small text with squinting or leaning in.",
        _obj({"direction": {"type": "string", "enum": ["in", "out", "reset"]},
              "steps": {"type": "integer", "minimum": 1, "maximum": 3}}, ["direction"]),
        "action", "ask", False, "py", "distance_cm"),
    "suggest_posture_reset": (
        "Show a small card about posture when it has drifted (slumping, head dropping, leaning in). Write a short, warm "
        "message; posture drifting usually means the user is getting tired, so mention a stretch or a break.",
        _obj({"message": {"type": "string", "maxLength": 200}}, ["message"]),
        "action", "auto", True, "swift", "distance_cm"),
    "summarize_aloud": (
        "Summarize the current browser tab or selected text with the on-device model and speak it, so the user can "
        "rest their eyes instead of reading. The text never leaves the Mac for the summary. Medium disruption; ask first.",
        _obj({"source": {"type": "string", "enum": ["browser_tab", "selection"]}}, ["source"]),
        "action", "ask", True, "py", "gaze_on_screen_pct"),
    "suggest_seeing_eye_doctor": (
        "Show a calm card suggesting the user mention a week of eye-strain signs to an eye doctor. Only works when the "
        "code-enforced eligibility rule is met. Never diagnose.",
        _obj({"evidence": {"type": "string", "maxLength": 300}}, ["evidence"]), "action", "ask", True, "swift", None),
}

FIRST_USE_READS = {"get_calendar_events"}
SCREEN_TOOLS = {"describe_screen", "summarize_aloud"}  # need the on-device screen description (agent.offered)
SILENT = {n for n, v in CATALOG.items() if not v[4]}


def meta(name):
    d, s, kind, tier, ui, ex, target = CATALOG[name]
    return {"name": name, "description": d, "kind": kind, "tier": tier, "ui": ui, "executor": ex, "target": target}


def schemas():
    return [{"name": n, "description": v[0], "input_schema": v[1]} for n, v in CATALOG.items()]


def validate(name, args):
    """Minimal JSON-schema check for our own flat schemas. Returns an error string or None."""
    if name not in CATALOG:
        return f"unknown tool {name}"
    schema = CATALOG[name][1]
    if not isinstance(args, dict):
        return "args must be an object"
    for r in schema["required"]:
        if r not in args:
            return f"missing {r}"
    for k, v in args.items():
        p = schema["properties"].get(k)
        if p is None:
            return f"unexpected arg {k}"
        t = p["type"]
        ok = {"boolean": isinstance(v, bool), "string": isinstance(v, str), "array": isinstance(v, list),
              "integer": isinstance(v, int) and not isinstance(v, bool),
              "number": isinstance(v, (int, float)) and not isinstance(v, bool)}[t]
        if not ok:
            return f"{k} must be {t}"
        if "enum" in p and v not in p["enum"]:
            return f"{k} must be one of {p['enum']}"
        if "minimum" in p and v < p["minimum"] or "maximum" in p and v > p["maximum"]:
            return f"{k} out of range"
        if "maxLength" in p and len(v) > p["maxLength"]:
            return f"{k} too long"
        if "maxItems" in p and len(v) > p["maxItems"]:
            return f"{k} has too many items"
        item = p.get("items", {})
        if "maxLength" in item and any(not isinstance(x, str) or len(x) > item["maxLength"] for x in v):
            return f"each {k} item must be a string of at most {item['maxLength']} characters"
    return None

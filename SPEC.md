# eyeOS — Specification

An eye-strain coach for macOS. A webcam and Google MediaPipe track your face. eyeOS computes eye-strain and fatigue metrics from the landmarks. An AI agent (Claude) reasons over those metrics and adjusts your Mac or nudges you to rest. Every reasoning step and every action is logged and shown in the app.

Status: hackathon build, demo-first. Decisions below were settled in a design review. Anything marked **nice-to-have** comes after the must-demo set works end to end.

---

## 1. Goals and non-goals

### Goals
- Measure eye-strain signals live from the face landmarks: blink rate, incomplete blinks, longest stare, blink duration, PERCLOS, squint, screen distance, looking away, head pose, eye rubbing, yawning, room brightness, presence and session time.
- Let an agent decide when and how to step in, using macOS system settings, on-screen nudges, text-to-speech and context such as the active app, the time of day and the calendar.
- Ask the user before the first use of any action tool, then follow per-tool tiers.
- Log everything: metrics, events, agent reasoning, tool calls, approvals and the measured outcome of each intervention.
- Ship a native-feeling macOS app with three pages (Live, Log, Settings) and a menu bar extra.
- Make the live demo reliable (demo mode).

### Non-goals (hackathon)
- No medical claims. eyeOS never diagnoses anything (see §9.6).
- No bundling or signing the Python runtime into the `.app`.
- No App Store sandboxing.
- No refresh-rate or flicker control, no `snooze_until_break`, no ambient-light-sensor reading (cut).
- No text-to-speech from arbitrary apps or PDFs. Audio covers browser tabs and selected text only.
- No automated UI or agent tests. Only the metric math is tested.

---

## 2. Architecture

```
┌──────────────────────── eyeOS.app (SwiftUI) ────────────────────────┐
│  Live page · Log page · Settings · Onboarding · Menu bar extra       │
│  UI tools: ask_user dialog, blink edge-pulse, exercise overlay,     │
│            look-away card, audio panel, (calendar via EventKit)     │
│  Keychain (API keys) · spawns + supervises sidecar                  │
└───────────────▲─────────────────────────────────────┬───────────────┘
                │ WebSocket 127.0.0.1:<port> (token)  │
                │ JSON text msgs + binary JPEG frames │
┌───────────────┴─────────────────────────────────────▼───────────────┐
│                     sidecar (Python, uv)                             │
│  camera (OpenCV) → MediaPipe Face Landmarker (+blendshapes, 30 fps)  │
│                  → MediaPipe Hand Landmarker (every 3rd frame)       │
│  metrics engine → trigger engine → agent loop (Anthropic API)        │
│  system tools (osascript / defaults / shortcuts / screencapture)     │
│  Cartesia TTS → afplay · outcome evaluator · SQLite                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Responsibilities

| Concern | Owner |
|---|---|
| Camera capture | Python, the only process that opens the camera |
| Landmarks, blendshapes, metrics, triggers | Python |
| Agent loop, prompts, Anthropic calls | Python |
| System tools (dark mode, Focus, windows, screenshot, active app) | Python |
| TTS synthesis and playback | Python (Cartesia → WAV → `afplay`) |
| Persistence (SQLite) | Python |
| Rendering, UI tools, dialogs, overlays | Swift |
| API key storage | Swift (Keychain), passed to the sidecar as environment variables |
| Calendar (EventKit), nice-to-have | Swift, answers a `tool_exec` request |
| Sidecar lifecycle | Swift |

Swift never makes decisions. It renders, collects input and runs the few tools that need AppKit or EventKit.

### Repo layout

```
eyeOS/
├── SPEC.md
├── protocol.md              # canonical WS message reference (generated from §6)
├── app/                     # Xcode project: eyeOS (SwiftUI, macOS 14+)
│   └── eyeOS/
│       ├── App.swift
│       ├── Sidecar.swift            # spawn, supervise, WS client
│       ├── Models.swift             # Codable mirrors of protocol messages
│       ├── Pages/LiveView.swift
│       ├── Pages/LogView.swift
│       ├── Pages/SettingsView.swift
│       ├── Onboarding/…
│       ├── Overlays/…               # edge pulse, exercise, look-away card, audio panel
│       ├── MenuBar.swift
│       └── Resources/Sounds/{chime,rain,bowl}.wav
└── sidecar/
    ├── pyproject.toml
    ├── models/              # face_landmarker.task, hand_landmarker.task (fetched by script)
    ├── scripts/fetch_models.sh
    ├── eyeos/
    │   ├── __main__.py      # CLI: --port --token --print --record --replay
    │   ├── camera.py
    │   ├── vision.py        # MediaPipe wrappers
    │   ├── metrics.py       # pure functions + rolling-window state machines
    │   ├── triggers.py
    │   ├── agent.py         # context builder, Anthropic loop, approval gating
    │   ├── tools/           # one module per tool group
    │   ├── outcomes.py
    │   ├── tts.py
    │   ├── db.py
    │   ├── server.py        # websockets server
    │   └── demo.py          # demo-mode seeding
    └── tests/
        ├── fixtures/        # recorded landmark sessions (.jsonl.gz)
        └── test_metrics.py
```

### Runtime and dependencies
- **Swift:** macOS 14+, SwiftUI, `URLSessionWebSocketTask`, Security (Keychain), EventKit (nice-to-have). No third-party packages.
- **Python:** 3.11 or 3.12, managed with `uv`. Dependencies are `mediapipe`, `opencv-python`, `numpy`, `anthropic`, `cartesia`, `websockets`, `pyobjc-framework-Cocoa` and `pyobjc-framework-Quartz` (frontmost app, idle time), and `pytest` (dev).
- **Models:** `face_landmarker.task` (with blendshapes and facial transformation matrices) and `hand_landmarker.task`, downloaded by `scripts/fetch_models.sh` from Google's MediaPipe model storage.

### Sidecar lifecycle
1. When the app launches, Swift generates a random port (or uses 8765 in dev) and a random 32-byte hex token.
2. Swift runs `uv run --project <repo>/sidecar python -m eyeos --port P --token T`, with env `ANTHROPIC_API_KEY` and `CARTESIA_API_KEY` taken from the Keychain. The repo path comes from Settings and defaults to the dev path.
3. Swift connects to `ws://127.0.0.1:P/?token=T`. Python rejects any connection with a wrong token (close code 4401). Python binds to 127.0.0.1 only.
4. If the process crashes, Swift restarts it with backoff (1 s, 3 s, 10 s). After 3 failures in 2 minutes it shows a banner with the last 50 lines of stderr.
5. When the app quits, Swift sends `command:shutdown`, waits 2 s, then sends SIGTERM.
6. Changing API keys restarts the sidecar.

Standalone dev modes:
- `python -m eyeos --print` runs headless and prints the metrics line and events to stdout at 2 Hz. No WebSocket.
- `python -m eyeos --record out.jsonl.gz` dumps per-frame landmarks, blendshapes, transform and hands (see §11).
- `python -m eyeos --replay in.jsonl.gz --print` feeds a recording through the metrics engine.

### Permissions (macOS TCC)
Because the app spawns the sidecar, the sidecar's prompts are attributed to eyeOS.app, the parent app. During development from a terminal they're attributed to the terminal instead.

| Permission | Why | Info.plist key |
|---|---|---|
| Camera | webcam | `NSCameraUsageDescription` |
| Screen Recording | screenshots for the agent and screen brightness | (none; System Settings) |
| Accessibility | window move/resize, front window title, reader-mode keystroke | (none; System Settings) |
| Automation (System Events, Safari, Google Chrome) | dark mode, page text, window ops | `NSAppleEventsUsageDescription` |
| Calendars (nice-to-have) | `get_calendar_events` | `NSCalendarsFullAccessUsageDescription` |

App target settings: App Sandbox **off** and Hardened Runtime off for dev builds.

---

## 3. Vision pipeline

- **Capture:** `cv2.VideoCapture(0)` (AVFoundation) at 640×480, 30 fps requested. The frame is mirrored for display only. All math uses unmirrored coordinates.
- **Face:** MediaPipe `FaceLandmarker` with:
  - `running_mode=LIVE_STREAM`
  - `num_faces=1`
  - `output_face_blendshapes=True`
  - `output_facial_transformation_matrixes=True`
  - `min_face_detection_confidence=0.5`, `min_tracking_confidence=0.5`

  Timestamps are monotonic ms.
- **Hands:** MediaPipe `HandLandmarker`, `num_hands=2`, `LIVE_STREAM`, run on every 3rd frame (about 10 fps).
- **Outputs per frame:** 478 face landmarks (normalized x and y, relative z), 52 blendshapes, a 4×4 head transform, and 0–2 hands with 21 landmarks each.
- **Luma:** the mean of the grayscale frame (0–255), computed every 10th frame.
- **No face:** if no face is detected, `face_present=false` and eye metrics pause. Windows count only frames where a face is present.

Frames are **never persisted**. They're only kept in memory for display and for an on-demand agent image.

---

## 4. Metrics: definitions and calculations

All coordinates are normalized image coordinates unless noted. `‖a−b‖` is the 2-D Euclidean distance after scaling x by the frame width and y by the frame height, so pixels are square. "Right eye" means the **subject's** right eye.

### 4.1 Landmark indices (MediaPipe Face Mesh, 478 points)

| Feature | Indices |
|---|---|
| Right eye EAR (p1..p6) | 33, 160, 158, 133, 153, 144 |
| Left eye EAR (p1..p6) | 362, 385, 387, 263, 373, 380 |
| Right eye corners (outer, inner) | 33, 133 |
| Left eye corners (inner, outer) | 362, 263 |
| Right iris center, ring | 468; 469, 470, 471, 472 |
| Left iris center, ring | 473; 474, 475, 476, 477 |
| Iris horizontal diameter | right 469↔471, left 474↔476 |
| Right eye upper/lower lid (vertical gaze) | 159, 145 |
| Left eye upper/lower lid | 386, 374 |
| Eye centers (for rub detection) | mean of each eye's 6 EAR points |
| Inter-ocular distance (IOD) | ‖33 − 263‖ |
| Mouth (MAR fallback) | 13, 14 (vertical); 78, 308 (horizontal) |

Hand fingertips (MediaPipe Hands): 4, 8, 12, 16, 20.

### 4.2 Eye Aspect Ratio and openness
```
EAR_eye = (‖p2−p6‖ + ‖p3−p5‖) / (2 · ‖p1−p4‖)
EAR     = mean(EAR_right, EAR_left)
o       = clamp(EAR / EAR_open_baseline, 0, 1.2)     # normalized openness, 1.0 = your normal open eye
```
`EAR_open_baseline` is the median EAR during calibration step 3 (§7), using only frames that are not inside a dip. Before calibration it defaults to 0.28.

Smoothing: none on `o` for blink detection, because blinks are only 3–12 frames long. For display, use an EMA with α=0.3.

### 4.3 Blink, incomplete blink and blink duration: one dip state machine
A **dip** is any lid-lowering event. There's one detector with hysteresis:

```
state OPEN:   if o < 0.75 → state DIP, start = t, min_o = o
state DIP:    min_o = min(min_o, o)
              if o > 0.85 → end = t; classify; state OPEN
              if (t − start) > 3.0 s → state CLOSED (eyes shut, not a blink)
state CLOSED: if o > 0.85 → state OPEN (emit eyes_closed event with duration)
```

Classification on dip end, with `frames = number of frames in DIP`:

| Condition | Result |
|---|---|
| `frames < 2` | noise, ignored |
| `min_o ≤ 0.20` | **complete blink**, `duration = end − start` |
| `0.20 < min_o ≤ 0.60` | **incomplete blink** |
| `min_o > 0.60` | noise, ignored |
| complete blink with `duration > 0.5 s` | also flagged **long blink** (fatigue) |

The 2-frame minimum matches the "below threshold for 2–3 frames" rule. A threshold `o ≤ 0.20` means the lids are ≥ 80% closed, the same definition PERCLOS uses. Threshold constants live in settings (§8) under `advanced.*`.

Derived metrics:

| Metric | Definition | Window |
|---|---|---|
| `blink_rate` | complete blinks ÷ face-present minutes | rolling 60 s |
| `incomplete_rate` | incomplete blinks per minute | rolling 60 s |
| `incomplete_pct` | incomplete ÷ (complete + incomplete) | rolling 60 s (needs ≥ 5 dips, else null) |
| `blink_duration_ms` | mean duration of complete blinks | rolling 60 s |
| `long_blink_count` | long blinks | rolling 60 s |
| `longest_stare_s` | max gap between consecutive dips (complete or incomplete) whose start falls in the window. The ongoing gap since the last dip counts. | last 5 min |
| `current_stare_s` | seconds since the last dip ended | instant |

A stare clock pauses while the face is absent or looking away (§4.6), since a stare is only counted at the screen.

### 4.4 PERCLOS
```
PERCLOS = (frames with o ≤ 0.20) / (face-present frames)   over rolling 60 s
```
Reported as a percentage. Reference: < 8% alert, 8–15% borderline, > 15% drowsy.

### 4.5 Squint
Computed only on frames in state OPEN, with no dip in progress.
```
squint_blend = mean(eyeSquintLeft, eyeSquintRight)
brow_blend   = mean(browDownLeft, browDownRight)
squint_score = squint_blend + 0.5 · brow_blend
squint_delta = squint_score − squint_score_baseline
open_ratio   = mean(o) over open frames                # < 1.0 = narrower than your normal
squinting    = squint_delta > 0.15  OR  open_ratio < 0.80
```
Window: rolling 10 s for `squinting`. A **sustained squint** is `squinting` true for ≥ 30 s (a trigger, §5).

### 4.6 Screen distance (iris)
The human iris is about 11.7 mm across, so distance follows a pinhole model:
```
w_px     = mean(‖469−471‖, ‖474−476‖)                 # iris diameter in pixels
f_px     = w_px_cal · D_cal / 11.7                     # from calibration step 1, D_cal = 600 mm
distance_cm = (f_px · 11.7 / w_px) / 10
```
This simplifies to `distance = D_cal · w_px_cal / w_px`. Smoothing: a median over 15 frames, then an EMA with α=0.1. If yaw is beyond 30°, the iris is foreshortened, so distance holds its last value and is marked stale. Before calibration, assume `f_px = frame_width` (shown as "uncalibrated").

### 4.7 Head pose
Head pose comes from MediaPipe's facial transformation matrix (4×4). Decompose the rotation into yaw, pitch and roll in degrees. This is equivalent to running `cv2.solvePnP` on nose tip 1, chin 152, eye corners 33 and 263, and mouth corners 61 and 291 with a canonical 3-D face. Use the solvePnP route only if the matrix proves noisy. Values are made relative to the calibration "center" pose.

| Metric | Definition |
|---|---|
| `yaw_deg`, `pitch_deg`, `roll_deg` | relative to calibrated center |
| `head_tilt` (nice-to-have) | abs(roll) > 12° sustained 60 s |
| `chin_drop` (nice-to-have) | pitch < −15° sustained 60 s **while gaze on screen** |
| `forward_lean` (nice-to-have) | linear-regression slope of `distance_cm` over the last 10 min < −1.0 cm/min |

### 4.8 Gaze and looking away
For each eye, take the horizontal iris position between the corners:
```
gx_right = (x468 − x33)  / (x133 − x33)                # 0 = outer corner, 1 = inner corner
gx_left  = (x473 − x263) / (x362 − x263)
gx       = mean(gx_right, gx_left)                     # ≈0.5 = center
gy       = mean((y468 − y159)/(y145 − y159), (y473 − y386)/(y374 − y386))
```
`gaze_on_screen` is true when:
- `gx` is within `[cal_gx_min − 0.05, cal_gx_max + 0.05]`, from calibration step 2's center-of-screen sweep, **and**
- `|yaw| < 25°`, **and**
- `pitch > −35°`

**Looking away** means a face is present but `gaze_on_screen` is false, or there is no face.

Pitch strongly down (−20° to −35°) with no yaw is treated as "keyboard/phone", which still counts as on screen. This is deliberate: looking down at a phone is not a rest.

A **real break** is looking away or no face continuously for ≥ 20 s (the 20-20-20 rule). The webcam can't verify focus at 20 ft, only that the user looked away from the screen. The agent is told this.

### 4.9 Eye rubbing
On hand frames, compute the distance from each fingertip (4, 8, 12, 16, 20) to each eye center:
```
near = min_fingertip_eye_dist < 0.35 · IOD
rub  = near for ≥ 0.7 s (cumulative within a 1.5 s window)
```
Rubbing usually occludes the eye, so a face-landmark dropout during `near` doesn't reset the timer. When it fires, the trigger engine emits an `eye_rub` event with a 30 s refractory period.

### 4.10 Yawning
```
yawn_open = jawOpen > 0.60    (fallback: MAR = ‖13−14‖/‖78−308‖ > 0.6)
yawn      = yawn_open sustained ≥ 1.5 s, then closes
```
`yawn_count_5m` counts yawns in the last 5 min. Speaking produces short jawOpen spikes, which the 1.5 s rule filters out.

### 4.11 Room and screen brightness
- **`room_luma`** is the mean grayscale of the webcam frame (0–255), averaged over 5 s. It's approximate because camera auto-exposure compensates. `dark_room = room_luma < 60`.
- **`screen_luma`** comes from `screencapture -x -t jpg` of the main display every 30 s, downscaled to 64 px, with mean luma 0–255. `bright_screen = screen_luma > 170 AND dark_mode == false`. Dark mode state comes from `defaults read -g AppleInterfaceStyle`.
- **Mismatch:** `dark_room AND bright_screen` sustained for 60 s.

### 4.12 Presence and session
| Metric | Definition |
|---|---|
| `face_present` | face detected in the last 0.5 s |
| `presence_s` | continuous seconds present. Absences < 5 s are bridged. |
| `session_s` | time since the session started. A session ends after absence ≥ 2 min. |
| `since_real_break_s` | seconds since the end of the last real break (§4.8) |
| `screen_time_today_s` | sum of face-present seconds today |

### 4.13 Metrics snapshot (5 Hz to the UI, 1 Hz to the DB)
```json
{
  "ts": 1761264000.123,
  "face_present": true,
  "o": 0.93,
  "ear": 0.27,
  "blink_rate": 7.0,
  "incomplete_rate": 4.0,
  "incomplete_pct": 0.36,
  "blink_duration_ms": 180,
  "long_blink_count": 0,
  "current_stare_s": 6.2,
  "longest_stare_s": 21.4,
  "perclos": 0.04,
  "squint_delta": 0.08,
  "open_ratio": 0.91,
  "squinting": false,
  "distance_cm": 48.2,
  "distance_stale": false,
  "yaw_deg": -3.1, "pitch_deg": -8.0, "roll_deg": 1.2,
  "gx": 0.52, "gy": 0.47,
  "gaze_on_screen": true,
  "rubbing": false,
  "yawn_count_5m": 0,
  "room_luma": 92, "screen_luma": 201, "dark_mode": false,
  "presence_s": 1430, "session_s": 2810, "since_real_break_s": 1310,
  "screen_time_today_s": 14200,
  "fps": 29.6,
  "calibrated": true,
  "eye_score": 84,
  "zen": false
}
```

### 4.14 Eye score
A 0–100 summary of the live strain signals for the Live page (100 = relaxed). `null` without a face or before calibration. It starts at 100 and subtracts:
- blink rate below the user's baseline: up to 30 (linear, 0 at baseline, 30 at 0/min)
- `incomplete_pct` 0.2 → 0.6: up to 15
- `current_stare_s` 10 → 30 s: up to 10
- `perclos` 0.08 → 0.20: up to 15
- `distance_cm` 50 → 35 cm: up to 10
- `since_real_break_s` 20 → 60 min: up to 10
- squinting: 10

It is display-only; the agent and triggers use the raw metrics.

---

## 5. Triggers

The trigger engine runs on each 5 Hz snapshot. Triggers are deterministic, so the LLM is only woken when something is worth reasoning about.

| id | Condition (default) | Demo-mode value |
|---|---|---|
| `low_blink_rate` | `blink_rate < 8` sustained 120 s | 30 s |
| `long_stare` | `current_stare_s > 15` | 8 s |
| `incomplete_blinks` | `incomplete_pct > 0.40` sustained 60 s | 20 s |
| `drowsy` | `perclos > 0.15` | same |
| `long_blinks` | `long_blink_count ≥ 3` in 60 s | same |
| `sustained_squint` | `squinting` ≥ 30 s | 10 s |
| `too_close` | `distance_cm < 40` sustained 60 s | 15 s |
| `eye_rub` | rub event | same |
| `yawning` | `yawn_count_5m ≥ 2` | ≥ 1 |
| `dark_room_bright_screen` | mismatch (§4.11) 60 s | 15 s |
| `no_break` | `since_real_break_s > 1200` (20 min) | 120 s |
| `break_taken` | a real break just ended. Used to evaluate a pending `suggest_look_out_window` or exercise and to clear `no_break`. | same |
| `heartbeat` | every 900 s while face present | 180 s |

Rate limiting:
- Each trigger id has a **cooldown** (default 600 s, demo 45 s) after it fires.
- **Global minimum gap** between LLM calls: 120 s (demo 30 s).
- **One agent run at a time.** Triggers that fire during a run, or inside the global gap, are queued and **merged** into the next run's trigger list.
- `eye_rub` bypasses the global gap (but not its cooldown), because instant reaction is the demo moment.
- `heartbeat` is skipped if any other trigger ran within the last heartbeat interval.
- No triggers fire while tracking is paused, uncalibrated, or face absent > 2 min.
- **Zen mode (§9.11):** triggers are still evaluated and logged, but the queue is cleared and no agent run starts.

Each fired trigger is written to `events` (§10) and streamed to the UI.

---

## 6. WebSocket protocol

Python is the server and Swift is the only client. Text frames carry JSON `{ "type": "...", ...payload }`. Binary frames carry camera images. This section is the source of truth. `protocol.md` mirrors it.

### 6.1 Binary frames (Python → Swift)
```
bytes 0..7   : float64 little-endian timestamp (unix seconds)
bytes 8..    : JPEG (640×480, quality 70)
```
These are sent at 15 fps **only when** setting `ui.show_camera_image == true`.

### 6.2 Python → Swift

| type | payload | rate |
|---|---|---|
| `hello` | `{version, calibrated, paused, settings}` | on connect |
| `status` | `{camera_ok, face_present, paused, paused_until, calibrated, fps, agent_busy, demo_mode, has_claude, zen: {active, since, source, held_back, duration_s}, today: {screen_time_s, breaks, rubs, yawns, nudges, zen_s, longest_zen_s, avg_blink_rate, avg_eye_score}}` | on change + 1 Hz (`today` recomputed every 30 s) |
| `landmarks` | `{ts, face: [[x,y],…478] \| null, hands: [[[x,y],…21],…], iris: {r:[x,y,r], l:[x,y,r]}}` | 15 fps |
| `metrics` | snapshot (§4.13) | 5 Hz |
| `event` | `{id, ts, kind, trigger_id, value, details}` | as they happen |
| `agent_run` | `{run_id, ts, phase: "started"\|"finished"\|"error", triggers:[…], error?}` | per run |
| `agent_thinking` | `{run_id, text}` | per thinking block |
| `agent_text` | `{run_id, text}` | per text block |
| `tool_call` | `{run_id, call_id, name, args, status, result?, tier, executor}` | status changes |
| `outcome` | `{action_id, call_id, tool, metric, before, after, verdict}` | ~5 min after action |
| `ui_request` | `{request_id, kind, payload, timeout_s}` | when a UI tool runs |
| `ui_dismiss` | `{request_id}` | e.g. audio finished |
| `tool_exec` | `{request_id, name, args}` | Swift-executed tools (calendar) |
| `calibration` | `{step, phase: "started"\|"progress"\|"done"\|"failed", progress, result?}` | during calibration |
| `history` | `{request_id, rows:[…], kind}` | reply |
| `summary` | `{date, text, stats}` | reply |
| `settings` | `{settings}` | reply / on change |
| `approvals` | `{tools: {name: {tier, approval}}}` | reply / on change |
| `error` | `{code, message}` | as needed |

`tool_call.status` takes these values:
- `requested`
- `awaiting_approval`
- `approved`
- `declined`
- `blocked_suppressed`
- `blocked_tier`
- `executing`
- `done`
- `failed`

`ui_request.kind` and its payload:

| kind | payload | expected `ui_response.result` |
|---|---|---|
| `ask_user` | `{question, options:[str], allow_free_text:bool, context?}` | `{choice: str \| null, text?: str}`. `null` means timed out (60 s). |
| `approval` | `{tool, args, reason, question}` (first use / ask tier) | `{approved: bool, remember: bool}` |
| `blink_pulse` | `{count, intensity: 0..1}` | `{shown: true}` |
| `look_away_card` | `{message, duration_s}` | `{dismissed_by: "timeout"\|"user"}` |
| `exercise` | `{type, duration_s, steps:[{text, seconds}]}` | `{completed: bool, elapsed_s}` |
| `audio_panel` | `{title, source}` | sent once; controls go via `command:audio_control` |
| `doctor_card` | `{message, evidence}` | `{dismissed: true}` |
| `notice` | `{text}` (generic toast, e.g. "Dark mode on") | none |
| `zen_recap` | `{duration_s, reason, source, held_back, blink_rate, baseline_blink_rate, longest_stare_s, suggest_rest}` (§9.11) | `{action: "rested"\|"later"\|"ok"}` |

### 6.3 Swift → Python

| type | payload |
|---|---|
| `ui_response` | `{request_id, result}` |
| `tool_result` | `{request_id, ok, result \| error}` |
| `command` | `{name, args?}`, where `name` is one of `pause {minutes?}` (with `minutes`, tracking resumes by itself; `status.paused_until` holds the deadline), `resume`, `break_now` (shows a 20 s `look_away_card` the user asked for), `shutdown`, `calibrate {step}`, `reset_approvals`, `seed_demo`, `wipe_demo`, `generate_summary {date?}`, `audio_control {action: pause\|resume\|stop}`, `run_agent_now` (debug), `zen {on: bool}` (start / end Zen manually) |
| `set_setting` | `{key, value}` |
| `get_settings` | `{}` |
| `get_approvals` | `{}` |
| `set_tool_tier` | `{tool, tier}` |
| `history_request` | `{request_id, kind: "metrics"\|"events"\|"runs", from, to, limit}`. Metrics rows carry `ts` plus `blink_rate, perclos, distance_cm, squint_delta, incomplete_pct, eye_score, current_stare_s, longest_stare_s, gaze_on_screen, blink_duration_ms, since_real_break_s, zen`. |
| `delete_preference` | `{id}` |

Python validates every inbound message: unknown types get an `error` reply, and settings keys and values are checked against §8 types and ranges.

---

## 7. Onboarding and calibration

Setup is kept to what tracking needs. Keys, permissions other than the camera, and Focus Shortcuts are optional and live in Settings (§8).

1. **Welcome:** one line ("Looks after your eyes while you work.") and three icon rows: video stays on your Mac, 15-second calibration, silent while you're in deep focus. **Get started** requests camera access natively (`AVCaptureDevice.requestAccess`) and restarts the sidecar on first grant. If access is denied, show a deep link to `…Privacy_Camera`. **Skip** marks setup done without calibrating; the Live header then shows "Not calibrated · set up".
2. **Calibration step 1 (distance, 3 s):** illustration (person ↔ ≈ 60 cm ↔ laptop), "Sit back at arm's length". Collect 3 s of iris widths and take the median as `w_px_cal`; `calibration.distance_cm` is the assumed distance.
3. **Calibration step 2 (gaze, 10 s):** a full-screen dot at the center, then the four corners, 2 s each. Record `gx`, `gy`, yaw and pitch. The center pose becomes the head-pose zero, and the corner extremes give `cal_gx_min/max` and `cal_gy_min/max`.
4. **Done:** "You're set". **Start using eyeOS** closes the sheet and starts **calibration step 3 (baseline, 60 s) in the background**: the median open-state EAR (`EAR_open_baseline`), `squint_score_baseline`, blink rate and blink duration. The Live header shows "Learning your normal blink rate · Ns" until it finishes, and `calibrated` becomes true.

Each calibration step shows a live "Face found" check; **Start** is disabled until a face is visible. The step shows a progress ring while running and advances automatically on `done`. If a step fails (no face for > 50% of the step), the `calibration` message reports `failed` with a reason and the step offers **Try again**. A failed background baseline shows "Baseline failed · retry" in the Live header.

**Recalibrate** (Settings → Camera, or the Live header pill) opens the same sheet at step 1.

---

## 8. Settings

Settings live in the SQLite `settings` table (key → JSON value), owned by Python. API keys are the exception and live in the Keychain. Swift edits settings via `set_setting`.

| Key | Type | Default | Notes |
|---|---|---|---|
| `ui.show_camera_image` | bool | true | on = Live page shows the camera; off = score-first layout, no JPEG frames sent (§11.1) |
| `ui.show_hud` | bool | true | ambient floating HUD over other apps (§11.4.1) |
| `tracking.paused` | bool | false | pause also releases the camera |
| `agent.enabled` | bool | true | off = metrics/triggers only, no LLM calls |
| `agent.model` | str | `claude-sonnet-5-5` | fallback `claude-haiku-5-5` |
| `agent.heartbeat_s` | int 60–3600 | 900 | |
| `agent.global_gap_s` | int 10–1800 | 120 | |
| `agent.trigger_cooldown_s` | int 10–3600 | 600 | |
| `agent.send_images` | bool | true | webcam frame + screenshot on event runs |
| `agent.max_tool_iterations` | int 1–10 | 6 | |
| `triggers.<id>.enabled` | bool | true | per trigger in §5 |
| `triggers.<id>.threshold` | number | §5 | |
| `triggers.<id>.sustain_s` | number | §5 | |
| `tools.<name>.tier` | `auto`\|`ask`\|`blocked` | §9 | |
| `zen.enabled` | bool | true | auto-detect deep focus (§9.11); manual Zen always works |
| `zen.enter_min` | number 1–60 | 10 | minutes of sustained focus before auto Zen |
| `quiet_apps` | [bundle id \| title substring] | see §9.4 | UI tools suppressed |
| `calibration.distance_cm` | number | 60 | |
| `advanced.dip_start_o` / `dip_end_o` / `complete_o` / `incomplete_max_o` / `long_blink_s` | numbers | 0.75 / 0.85 / 0.20 / 0.60 / 0.5 | |
| `advanced.real_break_s` | int | 20 | |
| `audio.voice_id` | str | a Cartesia default voice | |
| `audio.speed` | number | 1.0 | |
| `demo.enabled` | bool | false | §12 |
| `sidecar.repo_path` | path | dev path | Swift-side (UserDefaults) |

Settings page (one scrolling column of cards):
1. **Camera & calibration:** status, Recalibrate, show-camera toggle, pause tracking.
2. **Zen mode:** auto-detect toggle, minutes before Zen, Start / End Zen now.
3. **Agent:** on/off, model, check-in interval, minimum gap between runs, per-trigger cooldown (all in minutes), send images.
4. **Permissions:** Camera (required), Screen Recording, Accessibility, Automation, each with ✓ or a Grant button that requests and deep-links to the pane.
5. **Keys & voice:** Cartesia and Anthropic (Keychain), sidecar repo path, Save and restart; Focus Shortcuts check (`shortcuts list` for "eyeOS Focus On/Off"; missing disables `set_focus_mode`).
6. **Quiet apps:** an editable list.
7. **Memory:** the preferences the agent saved (deletable) and the current baseline values.
8. **Advanced** (collapsed): per-trigger enable / threshold / sustain with reset; the tools table (tier picker, approval state, description) with Reset approvals.
9. **Demo:** demo mode toggle, Seed history, Wipe seeded data, Run agent now, Run setup again.

---

## 9. Agent

### 9.1 Run loop
1. **Trigger(s)** are ready (§5).
2. **Build the context** (§9.3). Event runs get images if `agent.send_images` is on. Heartbeat runs never get images.
3. **Call** `messages.create` with the system prompt, tools (§9.5), thinking enabled (a small budget, about 2k tokens) and `max_tokens` around 2k. Thinking-config parameter names should be checked against the current `anthropic` SDK at implementation time.
4. **For each `tool_use` block**, run the gate (§9.2), then execute or refuse, and return a `tool_result`. The `tool_result` content says why a call was refused, e.g. `"blocked: user is on a call (zoom.us)"` or `"declined by user"`.
5. **Loop** until `stop_reason == "end_turn"` or `agent.max_tool_iterations` is reached.
6. **Persist** the run: the context snapshot JSON, every thinking and text block, every tool call with args, status and result, and the token usage. Stream all of it to the UI as it happens.
7. **Errors:** on an API error, retry once after 3 s. If it fails again, the run is marked `error`, logged and streamed, and the next trigger proceeds normally.

Every run is stateless: there's no conversation carried between runs. Continuity comes from the action history, outcomes and preferences in the context.

### 9.2 Gate (order matters)
1. **Unknown tool or invalid args** → `failed`, with the error returned to the model.
   Then **Zen** (§9.11): any action tool or UI tool → `blocked_suppressed` ("the user is in deep focus"). Read and memory tools still run.
2. **Tier `blocked`** → `blocked_tier`.
3. **Suppression:** if the active app matches `quiet_apps` and the tool is UI-interrupting (`ui: true` in §9.5) → `blocked_suppressed`.
4. **Hard rules:**
   - `suggest_seeing_eye_doctor` eligibility (§9.6).
   - Never use the same action tool > 3 times per hour.
   - `update_baseline` can't run within 10 min of an active trigger.
5. **Approval** (action tools only, `kind: action`):
   - If the tool has never been asked, always send an `approval` ui_request, whatever its tier. This is the **first-use rule**.
     - On approve, the stored approval is `approved` and the tool follows its tier from then on.
     - On decline, it stays `declined`, which behaves like tier `ask` from then on, and Python auto-saves a preference "User declined <tool> on <date> (context: <trigger>)".
   - Otherwise, tier `ask` → send `approval` each time, and tier `auto` → execute.
   - An approval request with no answer in 60 s counts as declined, but the decline is not remembered.
   - Read-only tools (`kind: read`) and memory tools skip approval, except `get_calendar_events` (privacy) and `get_screenshot`, which follow the first-use rule.
6. **Execute.** Python-executed tools run directly. Swift-executed tools go through `tool_exec` and `ui_request`, with a 10 s timeout for non-interactive calls.
7. **Schedule the outcome evaluation** (§9.7) for action tools that have a target metric.

Approvals persist in the `approvals` table across restarts. "Reset approvals" clears them all back to never-asked.

### 9.3 Context sent each run
User message content (JSON, plus up to 2 images):
```json
{
  "triggers": [{"id": "long_stare", "value": 21.4, "fired_at": "..."}],
  "now": {"local_time": "2026-10-23T22:14:05-07:00", "weekday": "Fri", "is_night": true},
  "snapshot": { /* §4.13, current */ },
  "trend_10m": [ /* 10 per-minute aggregates: blink_rate, incomplete_pct, perclos, distance_cm, squint_delta, room_luma, screen_luma, gaze_on_screen_pct, app_category */ ],
  "baseline": {"blink_rate": 16.2, "blink_duration_ms": 160, "ear_open": 0.29, "squint_score": 0.12, "distance_cm": 58},
  "active_app": {"name": "Safari", "bundle_id": "com.apple.Safari", "window_title": "…", "category": "reading"},
  "system_state": {"dark_mode": false, "focus_on": false, "audio_playing": false, "increase_contrast": false},
  "preferences": [{"id": 3, "rule": "Never change brightness or dark mode while Figma is open"}],
  "recent_actions": [ /* last 10: {ts, tool, args, status, outcome: {metric, before, after, verdict} | "pending"} */ ],
  "tool_approval_states": {"set_dark_mode": "approved", "switch_to_audio": "never_asked"},
  "today": {"screen_time_min": 236, "breaks": 4, "interventions": 7},
  "pending_suggestions": [ /* look-away / exercise awaiting break_taken confirmation */ ],
  "caveats": ["webcam cannot verify far focus; break = looked away ≥20 s", "camera auto-exposure makes room_luma approximate"]
}
```
Images, on event runs only:
1. The current webcam frame, 512 px wide, JPEG q70, labelled "webcam".
2. A screenshot of the main display, 1280 px wide, JPEG q70, labelled "screen", via `screencapture -x -t jpg` then a resize.

### 9.4 App categories and quiet apps
`category` is derived from the bundle id and window title:

| Category | Matches |
|---|---|
| `call` | `us.zoom.xos`, `com.apple.FaceTime`, `com.microsoft.teams2`, `com.tinyspeck.slackmacgap` + title contains "Huddle", any browser with title containing "Meet –", "Zoom", "Teams" |
| `coding` | `com.microsoft.VSCode`, `com.apple.dt.Xcode`, `com.todesktop.230313mzl4w4u92` (Cursor), `com.googlecode.iterm2`, `com.apple.Terminal`, `com.jetbrains.*`, `dev.zed.Zed` |
| `reading` | browsers (`com.apple.Safari`, `com.google.Chrome`, `company.thebrowser.Browser`, `org.mozilla.firefox`) not in `call`; `com.apple.Preview`, `com.apple.iBooksX` |
| `design` | `com.figma.Desktop`, `com.bohemiancoding.sketch3` |
| `other` | everything else |

The `quiet_apps` default is everything matching `call`. UI tools are suppressed there, while silent tools (dark mode, contrast, Focus, read tools, memory) still run.

### 9.5 Tool catalogue

Columns:
- **kind:** `action` / `read` / `memory`
- **tier:** the default after first-use approval
- **ui:** whether the tool interrupts visually or audibly (suppressible)
- **exec:** `py` / `swift`
- **target metric:** used for outcome evaluation (§9.7)

#### Must-demo

| Tool | Args | kind | tier | ui | exec | Mechanism | Target metric |
|---|---|---|---|---|---|---|---|
| `set_dark_mode` | `enabled: bool` | action | ask | no | py | `osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to <bool>'` | `squint_delta` |
| `set_increase_contrast` | `enabled: bool` | action | ask | no | py | see §14 risk R2 | `squint_delta` |
| `set_reduce_transparency` | `enabled: bool` | action | auto | no | py | see §14 R2 | — |
| `set_reduce_motion` | `enabled: bool` | action | auto | no | py | see §14 R2 | — |
| `set_focus_mode` | `enabled: bool, minutes?: int` | action | auto | no | py | `shortcuts run "eyeOS Focus On"` / `"… Off"`. If `minutes` is given, Python schedules the Off. | `blink_rate` |
| `remind_to_blink` | `count: 1–5, intensity: 0–1` | action | auto | yes (subtle) | swift | `ui_request: blink_pulse`, a soft glow pulsing at screen edges, borderless click-through window on all spaces | `blink_rate` |
| `suggest_look_out_window` | `message: str` | action | auto | yes | swift | `ui_request: look_away_card`, a small non-modal card, 20 s, natural phrasing written by the agent. Paired with `break_taken`. | `since_real_break_s` reset |
| `start_guided_eye_exercise` | `type: palming\|focus_shift\|deliberate_blink, duration_s: 20–120` | action | ask | yes | swift + py (voice) | `ui_request: exercise` (full-screen translucent overlay with animation and countdown) + Cartesia narration of fixed scripts | `blink_rate`, `incomplete_pct` |
| `play_ambient_cue` | `sound: chime\|rain\|bowl` | action | auto | yes (audio) | swift | `NSSound` from bundled resources | `blink_rate` |
| `switch_to_audio` | `source: browser_tab\|selection` | action | ask | yes | py | see §9.8 | `gaze_on_screen_pct` drop / rest |
| `stop_audio` | — | action | auto | no | py | kills `afplay` | — |
| `get_active_app` | — | read | — | no | py | `NSWorkspace.frontmostApplication` + window title via System Events `name of front window` | — |
| `get_time_of_day` | — | read | — | no | py | local time, `is_night` (20:00–06:00) | — |
| `get_screenshot` | — | read (first-use) | — | no | py | an on-demand screen image on a heartbeat run | — |
| `ask_user` | `question: str, options: [str] (≤4), allow_free_text?: bool` | read | — | yes | swift | `ui_request: ask_user`, a non-modal floating panel, 60 s timeout | — |
| `save_user_preference` | `rule: str, app?: str` | memory | — | no | py | insert into `preferences` | — |
| `get_user_baseline` | — | memory | — | no | py | — | — |
| `update_baseline` | `reason: str` | memory | ask | no | py | recompute from the last 30 min of non-triggered, open-state data | — |
| `generate_daily_summary` | `date?: str` | memory | — | no | py | §9.9 | — |

#### Nice-to-have

| Tool | Args | kind | tier | ui | exec | Mechanism | Target |
|---|---|---|---|---|---|---|---|
| `set_cursor_size` | `size: 1.0–4.0` | action | ask | no | py | §14 R2 (`com.apple.universalaccess mouseDriverCursorSize`) | `squint_delta` |
| `enlarge_active_window` | `fraction: 0.6–1.0` | action | ask | no | py | System Events: set position/size of front window to the fraction of the visible frame, centered | `distance_cm`, `squint_delta` |
| `move_window_closer_to_center` | — | action | ask | no | py | same, keeps size | `yaw_deg` abs |
| `apply_reading_mode` | — | action | ask | no | py | Safari: System Events keystroke ⌘⇧R. Chrome: `execute javascript` injecting reader CSS (larger font, max-width 70ch, high contrast); requires Chrome "Allow JavaScript from Apple Events". | `squint_delta` |
| `get_typing_activity` | — | read | — | no | py | `CGEventSourceSecondsSinceLastEventType` for key-down: seconds since last keypress, plus `typing_burst = last key < 2 s for ≥ 60 s of the last 90 s`. No Input Monitoring needed. | — |
| `get_calendar_events` | `hours_ahead: 1–12` | read (first-use) | — | no | swift | EventKit: `[{title, start, end, is_busy}]` | — |
| `suggest_seeing_eye_doctor` | `evidence: str` | action | ask | yes | swift | `ui_request: doctor_card`, gated by §9.6 | — |

#### Not tools (by design)
- **`log_intervention_result`** is automatic (§9.7), so outcomes never depend on the model remembering to log them.
- **Cut:** `set_screen_refresh_or_flicker`, `snooze_until_break` (no API; Focus covers it), `get_ambient_light` (no public API; `room_luma` stands in).

Tool definitions are written as Anthropic tool JSON schemas in `sidecar/eyeos/tools/__init__.py`. Each description says what the tool does, when it's appropriate, and its disruption level.

### 9.6 Medical-safety rules
- **Eligibility:** `suggest_seeing_eye_doctor` is only executable when, on ≥ 3 of the last 7 days (each with ≥ 60 min screen time), daily mean `blink_rate < 8` **or** `incomplete_pct > 0.4` **or** `eye_rub` events ≥ 5. The gate enforces this in code, and the model can't override it. It runs at most once per 7 days.
- **Wording:** the card always reads as a suggestion. Template: "Over the past week your eyes have shown signs often linked to eye strain or dryness (…evidence…). eyeOS can't diagnose anything, but it might be worth mentioning to an eye doctor or optometrist."
- The system prompt forbids diagnostic language ("you have dry eye", "disease") in every tool and text output.

### 9.7 Outcome evaluation (automatic)
For each executed action tool with a target metric:
- `before` = the mean of the target metric over the 2 min before the call.
- `after` = the mean over the 3 min after the call, starting 15 s after execution. Evaluation runs 3 min 15 s after the call.
- `verdict`:
  - `improved` if the metric moved in the good direction by ≥ 15% relative (or ≥ 2 blinks/min for `blink_rate`)
  - `worse` if it moved ≥ 15% in the bad direction
  - `neutral` otherwise
  - `inconclusive` if the face was present < 50% of the after-window
- For `suggest_look_out_window` and exercises, the verdict is `confirmed_break` or `no_break`, depending on whether a real break (§4.8) happened within 2 min.
- Results go into `outcomes`, are streamed as `outcome`, and appear in later contexts (`recent_actions`) and summaries.

### 9.8 Audio (`switch_to_audio`)
1. **Get the text:**
   - `browser_tab`: Safari uses `do JavaScript "document.body.innerText" in current tab of front window`. Chrome uses `execute front window's active tab javascript "…"`. The first 8,000 characters are run through a light cleanup (collapse whitespace, drop nav and footer lines < 30 chars).
   - `selection`: save the clipboard, send ⌘C via System Events, read the clipboard, then restore it.
   - If the result is empty, the tool fails with a reason.
2. **Synthesize:** split into paragraphs of ≤ 600 characters. For each one, call the Cartesia TTS bytes endpoint (WAV) and cache it to `~/Library/Caches/eyeOS/tts/<hash>.wav`.
3. **Play:** run `afplay` sequentially and prefetch the next chunk while the current one plays. Pause uses `SIGSTOP` and resume uses `SIGCONT` on the `afplay` pid, and stop kills it and clears the queue.
4. **UI:** send `ui_request: audio_panel` (title = window title), a small floating panel with pause, resume and stop. When playback finishes, send `ui_dismiss`.

Exercise narration uses the same TTS path with fixed scripts, cached after first use.

### 9.9 Daily summary
1. Python aggregates in SQL for the date:
   - screen time
   - per-category mean blink rate, incomplete %, PERCLOS and distance
   - longest stare
   - number of breaks
   - interventions per tool, with verdict counts
   - most effective tool (best improved ratio, ≥ 2 uses)
2. Those stats go to Claude (no images, no tools) with the instruction to write 3–5 friendly sentences in a "you averaged 7 blinks/min while coding, 14 while reading; the font bump helped most" style.
3. The result is stored in `summaries` and shown at the top of the Log page.

This runs on demand only (a button or the agent tool).

### 9.10 System prompt (outline)
```
You are eyeOS, an eye-comfort assistant running on the user's Mac. You receive eye and
posture metrics computed from the webcam, context about what the user is doing, and
(sometimes) a webcam frame and a screenshot.

Goals, in order: protect the user's eyes and comfort; avoid breaking their focus;
learn what works for this person.

Rules:
- Before calling any tool, write 1–2 sentences explaining what you observe and why
  this action. Doing nothing is a valid choice — say why.
- Prefer the least disruptive effective action. Escalate only if earlier actions in
  recent_actions were neutral/worse.
- Do not repeat an action whose recent outcome was neutral/worse for the same trigger
  unless something changed.
- Respect every rule in preferences absolutely.
- If the user is in a call (category=call), only use silent tools.
- If unsure whether the user wants something disruptive, use ask_user with short options.
- When the user is typing in a burst, prefer to wait (no action) unless the signal is
  severe (eye_rub, drowsy).
- Never diagnose. Never use medical labels. Webcam cannot verify far-focus.
- Messages you write for the user are short, warm and natural, never nagging.
```

### 9.11 Zen mode (deep focus)
When the user is deep in focused work, eyeOS keeps measuring but becomes invisible: no agent runs, no overlays, sounds, approvals or system changes, the floating HUD hides, and the menu bar shows a plain eye icon (no blink count, no colored dot).

**Auto entry** (`zen.enabled`, window = `zen.enter_min`, default 10 min), checked at 1 Hz once calibrated and not paused. All must hold over the window:
- face present ≥ 85% of seconds, and gaze on screen ≥ 75% of those
- keyboard / mouse / scroll input within the last 60 s for ≥ 70% of seconds (`CGEventSourceSecondsSinceLastEventType`, any input)
- front app in a work category (`coding`, `design`, `writing`, `reading`) ≥ 80% of seconds, and never `call`
- no real break inside the window (`since_real_break_s` ≥ window)

**Auto exit:** a real break (looked away ≥ 20 s), face absent 60 s, no input 180 s, a non-work app in front 60 s, or a call.

**Manual:** `command:zen {on}` from the Live header, the menu bar or Settings. Manual Zen ends only when the user ends it (or a call starts). Ending Zen manually suppresses auto entry until the next real break.

**While active:** triggers are evaluated and logged (`details.zen = true`) and counted as `held_back`; the trigger queue is cleared and no run starts. The gate blocks visible tools (§9.2). On entry, any open `ui_request` is dismissed and resolved as no answer.

**Recap:** when a Zen session of ≥ 5 min (demo: 1 min) ends for any reason except `away`, one `zen_recap` banner shows the duration, the average blink rate vs. baseline and how many nudges were held back. If the session was ≥ 20 min or the blink rate fell below 70% of baseline, it offers **Rest eyes 20 s** (an in-card countdown) or **Later**.

**Logging:** `events` rows with `kind='zen'`: `zen_start` (details: source) and `zen_end` (value = duration s; details: reason, held_back, blink_rate, longest_stare_s). Zen time feeds the Live page's Today stats and timeline shading.

---

## 10. Persistence (SQLite)

File: `~/Library/Application Support/eyeOS/eyeos.db`, in WAL mode, with a single writer thread in Python. Timestamps are unix seconds (REAL). Every table has `seeded INTEGER DEFAULT 0` for demo data.

```sql
CREATE TABLE settings     (key TEXT PRIMARY KEY, value TEXT NOT NULL);           -- JSON value
CREATE TABLE metrics_1hz  (ts REAL PRIMARY KEY, data TEXT NOT NULL,              -- §4.13 JSON
                           app_category TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE events       (id INTEGER PRIMARY KEY, ts REAL, kind TEXT,           -- trigger|blink_anomaly|break|rub|yawn|zen|system
                           trigger_id TEXT, value REAL, details TEXT, run_id INTEGER, seeded INTEGER DEFAULT 0);
CREATE TABLE agent_runs   (id INTEGER PRIMARY KEY, ts_start REAL, ts_end REAL, status TEXT,
                           triggers TEXT, context TEXT, images_sent INTEGER,
                           thinking TEXT, text TEXT, model TEXT,
                           input_tokens INTEGER, output_tokens INTEGER, error TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE tool_calls   (id INTEGER PRIMARY KEY, run_id INTEGER, ts REAL, name TEXT, args TEXT,
                           status TEXT, tier TEXT, approval TEXT, result TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE outcomes     (id INTEGER PRIMARY KEY, call_id INTEGER, ts REAL, metric TEXT,
                           before REAL, after REAL, verdict TEXT, seeded INTEGER DEFAULT 0);
CREATE TABLE approvals    (tool TEXT PRIMARY KEY, state TEXT, ts REAL);         -- approved|declined
CREATE TABLE preferences  (id INTEGER PRIMARY KEY, ts REAL, rule TEXT, app TEXT, source TEXT); -- agent|user|auto_decline
CREATE TABLE baselines    (id INTEGER PRIMARY KEY, ts REAL, data TEXT, reason TEXT);  -- latest row = current
CREATE TABLE calibration  (id INTEGER PRIMARY KEY, ts REAL, step INTEGER, data TEXT);
CREATE TABLE summaries    (date TEXT PRIMARY KEY, ts REAL, text TEXT, stats TEXT, seeded INTEGER DEFAULT 0);
CREATE INDEX idx_events_ts ON events(ts);
CREATE INDEX idx_calls_run ON tool_calls(run_id);
```

**Retention:** `metrics_1hz` is pruned after 30 days. Everything else is kept. No images are ever stored, and the context JSON stores `images_sent` only, not image bytes.

---

## 11. UI

General: SwiftUI `NavigationSplitView` with a sidebar (Live, Log, Agent, Settings). The window closes to the menu bar and the app keeps running. A dark-friendly palette is used throughout.

### 11.1 Live page
A scrolling dashboard of cards (soft fill, hairline border, rounded 16 pt), with an icon on every tile and section.

- **Header** (both layouts): the title "Live"; status pills for tracking (Tracking · fps / Looking for you / Camera off / Paused), calibration (Learning your normal blink rate · Ns / Not calibrated · set up / Baseline failed · retry) and agent (watching / thinking / silent in Zen / off / unavailable); the **Zen button** (inactive: "Zen"; active: a gradient capsule "Zen · 23m · 3 held", click to end); and the **Camera toggle**, always in the same place.
- **Camera on** (`ui.show_camera_image`): camera view on the left with the overlay (sparse mesh, eye contours colored by `o`, iris circles, gaze vector, fingertips, head-pose gizmo, plus "Eye rub" / "Squinting" badges), the Today card under it; on the right the eye-score summary and a 2-column tile grid.
- **Camera off:** a hero card with a large eye-score ring (§4.14), a plain-words label (Eyes relaxed / Mild strain / Eyes working hard / Time to rest), the single biggest issue ("No real break for 32m") and, in Zen, a Zen line; Today stats on the right. Below it, a 4-column tile grid. No camera frames are streamed.
- **Tiles** (value + unit, one detail line, status dot; clicking a tile plots it on the timeline):

| Tile | Detail | Green / Amber / Red |
|---|---|---|
| Blink rate /min | your normal (baseline) | ≥ 12 / 8–12 / < 8 |
| Incomplete blinks % | "Blinks that don't fully close" | < 25 / 25–40 / > 40 |
| Stare s | longest stare | < 10 s / 10–20 s / > 20 s |
| Drowsiness (PERCLOS) % | "Time eyes are mostly closed" | < 8 / 8–15 / > 15 |
| Screen distance cm | calibrated distance | ≥ 50 / 40–50 / < 40 |
| Squint | lid tension or squint duration | relaxed / < 30 s / sustained |
| Last break | 20-20-20 countdown or "overdue", progress bar | < 20 min / 20–40 / > 40 |
| Focus / Zen focus | session or Zen length, eyes on screen % (last min) | — |

- **Today:** screen time, real breaks, time in Zen, average blinks/min, nudges (action tools run), eye rubs, from `status.today`.
- **Timeline:** a metric picker (eye score, blink rate, eye openness (live), incomplete blinks, stare, drowsiness, distance, squint, since last break, eyes on screen) and a range picker (**1m / 10m / 1h / Today**). 1m–1h come from a 1 Hz in-memory buffer (last hour); Today comes from `history_request` (480 rows, refreshed every 60 s). Data is averaged into ≤ 240 buckets; gaps without a face break the line. It draws an area + line in the metric's color, Zen periods shaded indigo, a dashed watch line and the user's baseline where defined, plus a Now / Average / Low / High (/ Baseline) row. "Eye openness (live)" is the 60 s dip trace with full (red), half (orange) and long (purple) blink markers.

### 11.2 Log page
- **Header:** the date picker, the "Daily summary" button, and the summary text when present.
- **Top half, the timeline:**
  - Swift Charts line charts sharing one x-axis (session or day): `blink_rate`, `perclos`, `distance_cm` and optionally `squint_delta`.
  - Vertical markers: trigger events (thin gray), agent runs (purple dot), and tool calls (icon per tool, colored by status).
  - Outcome verdict badges sit on the tool markers.
  - Brushing or zooming the x-axis filters the feed.
- **Bottom half, the feed:** reverse-chronological and live. Row types:
  - **Event:** time, trigger, value.
  - **Agent run (expandable):**
    - triggers
    - thinking (collapsed by default)
    - the rationale text
    - each tool call with args, approval and result
    - the outcome when it arrives
    - tokens and latency
  - **Outcome:** an inline update on the parent tool row.
  - **System:** calibration, pause and resume, errors.
- **Filters:** a toggle row (Events, Runs, Actions, Errors) and a search box.
- Clicking a chart marker scrolls the feed to that row and expands it.
- **Data:** a live stream plus `history_request` for past ranges, 500 rows per page.

### 11.3 Settings page
See §8 for the cards. It is a plain `ScrollView`, not a grouped `Form`.

### 11.4 Menu bar extra
- **Icon:** an eye glyph, plus the live blink rate (e.g. `👁 7`), plus a colored dot (worst card status). In Zen: the eye glyph only.
- **Popover** (`.window` style, 320 pt), answering "how am I doing?" from any app. It leads with the one thing to do, then the evidence:
  1. Eye-score ring, label and the top issue sentence (same `topIssue` as the Live hero card).
  2. Last real break, a bar toward the `no_break` threshold, and **Break now** (`command:break_now`).
  3. A 2×2 grid: blink rate (vs. normal), distance, posture, drowsiness. Dots use the same thresholds as the icon's dot.
  4. Eye score over the last 10 min (Zen shaded).
  5. One line each: what the conductor sees (and whether nudges are held), the last agent action, and today's screen time / breaks / Zen.
  6. Zen button; **Pause** for 15 min / 1 h / until resumed (shows **Resume** and the resume time when paused).
  7. Footer: Open Dashboard, an Agent menu (enabled, provider, run now, recalibrate), Settings, Quit.
- In Zen the popover shows only "Zen · duration · N nudges held" and the controls; while paused, only the paused line.

### 11.4.1 Floating HUD
A small always-on-top pill (`ui.show_hud`, on by default) for peripheral awareness while working in other apps. It is a non-activating `.floating` panel on all spaces, bottom-right by default (away from the banner stack), draggable, with its position remembered.
- **Calm** (all good): colored dot + time since the last real break, at 35% opacity.
- **Drifting** (dot amber, or a break is due): dot + the short top issue ("Blink more", "Sit back", "Too close", "Break due"), at 80%; at red, 100% with one soft pulse when it turns red. Never a repeating animation.
- **Hover:** full opacity, the full top-issue sentence, and **Break now** / **Hide**. Click opens the dashboard.
- **Hidden** in Zen, while paused, during meetings or entertainment (conductor), on calls, after 60 s with no face, and while the eyeOS window is in front.

### 11.5 Overlays (UI tools)
All overlays are borderless `NSPanel`s at `.screenSaver` or `.floating` level, shown on all spaces. They don't steal focus except `ask_user`, `approval` and `exercise`.

| Overlay | Description |
|---|---|
| **Blink pulse** | full-screen click-through window. An inner-edge gradient glow fades in and out (600 ms) `count` times. |
| **Look-away card** | bottom-right card with the agent's message, a 20 s ring timer and a "Done" button. The break itself is verified by the camera. |
| **Exercise** | full-screen at 85% black. A center animation per type (expanding circle for blink pacing; near/far dot for focus shift; "cover your eyes" hands illustration for palming), step text, countdown and Skip. Voice is played by Python. |
| **ask_user / approval** | top-right floating panel. The approval panel shows the tool, a plain-English effect, the agent's reason, and Allow / Not now / Never buttons. "Never" sets tier `blocked`. |
| **Audio panel** | a compact pill with title, pause/resume and stop. |
| **Doctor card** | centered, calm styling, text per §9.6, Dismiss. |
| **Notice** | a small toast ("Dark mode turned on"). |
| **Zen recap** | top-right banner after a Zen session (§9.11): duration, blink rate vs. normal, nudges held back; optional in-card 20 s rest countdown. |

---

## 12. Demo mode

Turned on in Settings → Demo.
- Uses the demo values from §5 for sustain durations, a 45 s trigger cooldown, `agent.global_gap_s=30` and `heartbeat=180`. The Zen recap shows after ≥ 1 min (instead of 5). Lower `zen.enter_min` to demo auto Zen, or start it manually.
- **Seed history** writes 7 days of synthetic `metrics_1hz` aggregates (at 1/min resolution, to keep it small), events, runs, tool calls and outcomes, and summaries, all with `seeded=1`. Seeded data has a declining blink rate (14 → 7 over the week) and rising incomplete %, so `suggest_seeing_eye_doctor` becomes eligible and the summary has a story.
- **Wipe seeded data** deletes `WHERE seeded=1`.
- **Reset approvals** (Settings → Tools) lets the first-use approval flow be shown again.

### Demo script (3 min)
1. Live page: show the mesh, then blink normally, do a half-blink (the incomplete marker appears on the dip trace), and stare. The stare counter climbs, then a pulse fires.
2. Rub your eyes. An instant agent run follows (reasoning streams in the Log), an approval panel appears for the exercise, you allow it, and the palming exercise starts with Cartesia voice.
3. Open a dense article and lean in and squint. The agent sees the screenshot and asks "Switch this article to audio?", then reads the article aloud.
4. Log page: show the reasoning, the tool calls and an `improved` outcome badge on the blink pulse.
5. Daily summary, then the (seeded) week view and the doctor-suggestion card wording.
6. Pitch points: incomplete-blink tracking, verified breaks, and outcome-driven learning.

---

## 13. Testing

- **`--record`:** writes one JSON line per frame, `{ts, face: [[x,y,z]…478] | null, blend: {name: score}, transform: [16], hands: [...], luma}`, gzipped.
- **Fixture session** `tests/fixtures/session_a.jsonl.gz` (about 2 min), with a scripted protocol the recorder follows:
  1. 20 s normal blinking, counted aloud
  2. 5 deliberate half-blinks
  3. a 20 s stare
  4. 3 long slow blinks
  5. 5 s eyes closed
  6. a 3 s eye rub
  7. 2 yawns
  8. look away for 25 s

  The recorder writes the ground-truth counts into `session_a.truth.json`.
- **`tests/test_metrics.py`** replays the fixture through `metrics.py` and asserts:
  - complete blink count within ±1
  - incomplete count within ±1
  - longest stare within ±1 s
  - long blinks = 3
  - eyes-closed event present (~5 s)
  - PERCLOS window during the closed segment > 0.08
  - 1 rub event
  - 2 yawns
  - 1 real break
- **Unit tests** cover the pure functions: EAR on a hand-built 6-point set, the distance formula, gaze ratio, the dip state machine on synthetic `o` sequences (a 2-frame dip gives a blink, a 1-frame dip gives noise, a dip with min 0.4 gives incomplete), and the outcome verdict math.
- The agent and UI are checked manually with the demo script. The gate logic (§9.2) gets a few unit tests because it has security implications: first-use always asks, blocked never executes, and suppression works.

---

## 14. Risks and day-1 spikes

| # | Risk | Spike / mitigation |
|---|---|---|
| R1 | MediaPipe Python on Apple Silicon: performance at 30 fps with blendshapes + hands | Measure fps in `--print` on day 1. If < 25 fps, run Hands every 5th frame and drop to 640×360. |
| R2 | Accessibility display toggles (increase contrast, reduce transparency, reduce motion, cursor size): `defaults write com.apple.universalaccess …` is protected on recent macOS and may not apply live | Test on day 1, in this order: (a) Shortcuts actions, if available on this macOS version, wrapped as "eyeOS Contrast On/Off" etc.; (b) `defaults write` + check it takes effect live; (c) GUI-script System Settings via Accessibility. If none works, demote these to nice-to-have and lean on dark mode. |
| R3 | TCC attribution to the parent app when the sidecar is spawned via `uv` | Verify that the camera, Screen Recording and Automation prompts name eyeOS.app. If not, launch the Python interpreter binary directly instead of through `uv`. |
| R4 | Focus has no public API | Use the Shortcuts approach (§7 step 3). |
| R5 | Camera auto-exposure skews `room_luma` | Treat it as approximate and say so in the agent caveats. Only use it combined with `screen_luma`. |
| R6 | LLM latency spoils the "instant" rub reaction | The rub trigger bypasses the global gap. Show a "thinking" state immediately, and fall back to Haiku 5.5 if Sonnet p50 > 6 s. |
| R7 | Chrome page-text extraction needs "Allow JavaScript from Apple Events" | Demo with Safari. Show a setup note in onboarding. |
| R8 | Thinking/tool API parameter names | Check against the installed `anthropic` SDK version before writing `agent.py`. |
| R9 | Localhost WebSocket reachable by other local processes | Token auth (§2) and 127.0.0.1 bind. Validate all inbound messages. |

---

## 15. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | Spikes R1–R3, R8 | fps measured, accessibility toggle method chosen, TCC attribution verified |
| M1 | Sidecar vision + metrics + `--print` / `--record` / `--replay` + tests | `pytest` green on the fixture. `--print` shows live metrics. |
| M2 | WS server + Swift Live page + menu bar + sidecar supervision | mesh and cards update live, and the camera toggle works |
| M3 | Triggers + agent loop + must-demo tools + approval gate + Log page | the rub → reasoning → approval → exercise flow works end to end and is logged |
| M4 | Onboarding + calibration + Settings page + outcomes + daily summary + TTS audio | first run from a clean DB works |
| M5 | Demo mode + seeding + doctor card + polish + nice-to-have tools | the demo script runs 3× in a row without a hitch |

---

## 16. Glossary
- **EAR:** eye aspect ratio, the lid opening relative to eye width.
- **o:** EAR normalized to the user's open-eye baseline.
- **Dip:** any drop in `o`. It is classified as a complete blink, an incomplete blink or noise.
- **PERCLOS:** the percentage of time the eyes are ≥ 80% closed.
- **Real break:** looking away from the screen, or absent, for ≥ 20 s.
- **First-use rule:** every action tool asks the user before its first use, then follows its tier.
- **Tier:** `auto` (run), `ask` (confirm each time), or `blocked` (never).

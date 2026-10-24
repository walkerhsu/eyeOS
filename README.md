# eyeOS

An eye-strain coach for macOS. See [SPEC.md](SPEC.md).

## Run

```sh
cd sidecar && uv sync && mkdir models && ./scripts/fetch_models.sh   # once
cd ../app && ./scripts/build_app.sh && open build/eyeOS.app
```

The app spawns the Python sidecar (`uv run … python -m eyeos`). The agent runs on the Claude Agent SDK and uses your local `claude` login (or `ANTHROPIC_API_KEY` if you set one in Settings → Keys). The Cartesia key is only needed for voice.

No Xcode needed: the app is a SwiftPM package wrapped into a `.app` by `build_app.sh`.

First launch opens a short setup: welcome (grants the camera), sit at arm's length (3 s), follow the dot (10 s). The 60 s blink baseline then runs in the background; the Live header shows its progress. Keys, other permissions and Focus Shortcuts are optional and live in Settings.

Each rebuild re-signs the app ad hoc, so macOS asks once for Keychain access to the saved keys. Click **Always Allow**; until you do, the app waits at launch with no window.

## Testing setup

**In the app.** Pick one:
- Settings → Demo → **Run setup again**: the full flow.
- Settings → Camera → **Recalibrate**, or the "Not calibrated" pill in the Live header: calibration steps only.
- As a true first run: `defaults delete dev.eyeos.app onboarded`, then relaunch. Add `tccutil reset Camera dev.eyeos.app` to see the camera prompt again.

Check that **Start** stays disabled until "Face found" shows, each step shows a progress ring and moves on by itself, a full-screen dot visits the center and four corners in step 2, and after **Start using eyeOS** the Live header counts down "Learning your normal blink rate" and then shows an eye score. Cover the camera during a step to see the failure and **Try again**.

**Without the UI.** Drive steps 1–3 against a second sidecar with a throwaway database. It needs camera access for your terminal, and stdin must stay open, because the sidecar exits on stdin EOF:

```sh
cd sidecar
sleep 300 | uv run python -m eyeos --port 8799 --token t --db /tmp/eyeos-test.db &
uv run python scripts/check_setup.py 8799 t   # prints done/failed + the calibration result per step
pkill -f "eyeos --port 8799"
```

## Zen mode

After `zen.enter_min` (default 10) minutes of sustained focus, eyeOS goes silent: no agent runs, overlays or sounds, and the menu bar shows a plain eye. Sustained focus means eyes on screen, active input, a work app in front and no real break. Metrics keep recording. Zen ends on a real break, being away, going idle, switching to a non-work app, or a call, and then a single recap card appears. Start or end it by hand from the Live header, the menu bar or Settings. See SPEC §9.11.

## Sidecar only

```sh
cd sidecar
uv run python -m eyeos --print                      # live metrics at 2 Hz
uv run python -m eyeos --record out.jsonl.gz        # Ctrl-C to stop
uv run python -m eyeos --replay out.jsonl.gz --print
uv run pytest
```

Running from a terminal makes macOS attribute the camera to the terminal app.

## Deviations from the spec

- Agent: Claude Agent SDK (`claude-agent-sdk`) with in-process MCP tools instead of the raw Messages API; the §9.2 gate runs inside each tool handler.
- Camera: always the Mac's built-in camera (never a Continuity Camera iPhone).
- Contrast / transparency / motion / cursor toggles go through user-created Shortcuts (`eyeOS Contrast On`, …): `defaults write com.apple.universalaccess` is refused on this macOS (R2).
- MediaPipe runs in VIDEO mode on a dedicated thread instead of LIVE_STREAM.
- `tests/fixtures/session_a.jsonl.gz` is not recorded yet; the fixture test is skipped until it exists (record it with `--record`, following §13, and write `session_a.truth.json`).

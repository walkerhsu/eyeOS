# eyeOS

An eye-strain coach for macOS. See [SPEC.md](SPEC.md).

## Run

```sh
cd sidecar && uv sync && ./scripts/fetch_models.sh   # once
cd ../app && ./scripts/build_app.sh && open build/eyeOS.app
```

The app spawns the Python sidecar (`uv run … python -m eyeos`). The agent runs on the Claude Agent SDK and uses your local `claude` login (or `ANTHROPIC_API_KEY` if you set one in Settings → Keys). The Cartesia key is only needed for voice.

No Xcode needed: the app is a SwiftPM package wrapped into a `.app` by `build_app.sh`.

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

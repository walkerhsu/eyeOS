#!/bin/bash
# Builds a self-contained eyeOS.app (its own Python, the sidecar's locked packages and the MediaPipe models) and a
# drag-to-Applications DMG in build/. Whoever downloads it needs nothing else installed.
#
# Usage: scripts/package_app.sh
#   EYEOS_VERSION=0.2.0                                  version in Info.plist and the DMG name (default 0.1.0)
#   SIGN_IDENTITY="Developer ID Application: … (TEAM)"   sign with the hardened runtime instead of ad hoc
#   NOTARY_PROFILE=eyeos                                 also notarize and staple (a `xcrun notarytool store-credentials` profile)
#
# Needs: uv, Xcode command line tools. Builds for this Mac's architecture (arm64 on Apple Silicon).
set -euo pipefail
cd "$(dirname "$0")/.."
APPDIR=$(pwd)
SIDECAR=$(cd ../sidecar && pwd)
PYVER=3.11                                    # matches requires-python and the tested .venv
VERSION=${EYEOS_VERSION:-0.1.0}
ARCH=$(uname -m)
APP=build/eyeOS.app
RES=$APP/Contents/Resources
DMG=build/eyeOS-$VERSION-$ARCH.dmg

step() { printf '\n==> %s\n' "$*"; }

step "Building the Swift app"
EYEOS_VERSION=$VERSION ./scripts/build_app.sh release

step "Embedding Python $PYVER"
uv python install "$PYVER" >/dev/null
PYBIN=$(uv python find --managed-python "$PYVER")  # python-build-standalone: relocatable, no system dependencies
cp -R "$(dirname "$(dirname "$PYBIN")")" "$RES/python"
PY=$RES/python/bin/python3
LIB=$RES/python/lib/python$PYVER
rm -f "$LIB/EXTERNALLY-MANAGED"

step "Installing the sidecar's locked dependencies"
uv export --project "$SIDECAR" --frozen --no-dev --no-hashes --no-emit-project --quiet -o build/requirements.txt
uv pip install --python "$PY" --no-cache --quiet -r build/requirements.txt

step "Copying the sidecar and models"
[ -f "$SIDECAR/models/face_landmarker.task" ] || "$SIDECAR/scripts/fetch_models.sh"
mkdir -p "$RES/sidecar/models"
cp -R "$SIDECAR/eyeos" "$RES/sidecar/"
cp "$SIDECAR"/models/*.task "$RES/sidecar/models/"

step "Trimming"
rm -rf "$RES/python/include" "$RES/python/share" "$LIB/test" "$LIB/idlelib" "$LIB/turtledemo" "$LIB/ensurepip" \
       "$LIB/site-packages/PyObjCTest" "$LIB/site-packages/pip" "$LIB/site-packages"/pip-*.dist-info
find "$RES" -name __pycache__ -type d -prune -exec rm -rf {} +
# precompiled, and checked by hash rather than mtime, so the read-only bundle never needs to write bytecode
"$PY" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$LIB" "$RES/sidecar/eyeos" >/dev/null || true

step "Checking that the sidecar imports"
(cd "$RES/sidecar" && "../python/bin/python3" -s -E -B -c '
import cv2, mediapipe, numpy, websockets, cartesia, claude_agent_sdk, objc, Quartz, AVFoundation
import eyeos.server, eyeos.vision, eyeos.agent
assert eyeos.agent.CLIS["claude"], "bundled claude CLI missing"
print("sidecar OK")')

step "Signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  ENT=scripts/eyeOS.entitlements
  # inside out: every Mach-O in the bundle, then the app. Code another Developer ID already signed (the claude CLI
  # bundled with claude-agent-sdk) keeps its own signature, which notarization accepts.
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q Mach-O || continue
    codesign -dvv "$f" 2>&1 | grep -q '^Authority=Developer ID Application' && continue
    codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$SIGN_IDENTITY" "$f"
  done < <(find "$RES" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0)
  codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"  # ad hoc: fine for your own Macs; others must clear the quarantine (see README)
fi
codesign --verify --strict "$APP"

step "Making $DMG"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "eyeOS" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    step "Notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

step "Done"
du -sh "$APP" "$DMG"

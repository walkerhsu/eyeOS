#!/bin/sh
# Builds eyeOS.app from the SwiftPM package (no Xcode needed). Usage: scripts/build_app.sh [debug|release]
set -e
cd "$(dirname "$0")/.."
CONF=${1:-debug}
swift build -c "$CONF"
APP=build/eyeOS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONF/eyeOS" "$APP/Contents/MacOS/eyeOS"
cp Resources/Sounds/*.wav "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.eyeos.app</string>
  <key>CFBundleName</key><string>eyeOS</string>
  <key>CFBundleExecutable</key><string>eyeOS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>eyeOS tracks blinks, gaze and distance from your face. Frames stay on your Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>eyeOS toggles dark mode, reads the current page aloud and arranges windows.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>eyeOS checks upcoming meetings so it doesn't interrupt you before them.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"  # ad-hoc: stable identity so TCC grants stick across launches
echo "built $APP"

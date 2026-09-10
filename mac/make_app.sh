#!/bin/bash
# Builds Bridg.app.
#
# `swift build` alone produces a bare Unix executable with no bundle identifier.
# UNUserNotificationCenter crashes outright in that case, and macOS will not
# grant Local Network access (needed for Bonjour) to an unbundled binary.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Bridg"
APP="build/Bridg.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bridg"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Bridg</string>
    <key>CFBundleDisplayName</key><string>Bridg</string>
    <key>CFBundleIdentifier</key><string>com.bridg.mac</string>
    <key>CFBundleExecutable</key><string>Bridg</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>

    <!-- Menu bar app: no Dock icon. -->
    <key>LSUIElement</key><true/>

    <!-- Required on macOS 15+ or Bonjour discovery silently returns nothing. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Bridg connects to your phone over your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_bridg._tcp</string></array>
</dict>
</plist>
PLIST

# Sign with a real identity if one exists — macOS denies notifications outright
# to ad-hoc-signed apps ("Notifications are not allowed for this application").
# Falls back to ad-hoc, which is enough for Local Network but not notifications.
# `|| true` — no matching identity makes grep exit 1, which under `set -eo
# pipefail` would kill the script (e.g. on a CI runner with no signing certs).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"' || true)"
codesign --force --deep --sign "${IDENTITY:--}" "$APP" 2>/dev/null \
    || echo "warning: codesign failed (app may not get network/notification permission)"
echo "signed with: ${IDENTITY:-ad-hoc}"

echo "Built $(pwd)/$APP"

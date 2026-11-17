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
SHARE_BIN="$(swift build -c "$CONFIG" --show-bin-path)/BridgShareExtension"
APP="build/Bridg.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp "$BIN" "$APP/Contents/MacOS/Bridg"
# Rendered from assets/logo.svg; regenerate both together.
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# --- Share extension -------------------------------------------------------
# The .appex is what puts Bridg into Finder's right-click "Share" submenu
# (next to AirDrop, Mail, Messages). It is a separate process that copies the
# shared items into its own sandbox container and wakes the app; the app then
# sends them to the selected phone.
APPEX="$APP/Contents/PlugIns/BridgShare.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$SHARE_BIN" "$APPEX/Contents/MacOS/BridgShareExtension"
cat > "$APPEX/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BridgShare</string>
    <key>CFBundleDisplayName</key><string>Bridg</string>
    <key>CFBundleIdentifier</key><string>com.bridg.mac.BridgShare</string>
    <key>CFBundleExecutable</key><string>BridgShareExtension</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>0.6.1</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
        <!-- Raw ObjC class name — see @objc(ShareExtension) in ShareExtension.swift. -->
        <key>NSExtensionPrincipalClass</key><string>ShareExtension</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>NSExtensionActivationRule</key>
            <dict>
                <key>NSExtensionActivationSupportsFilesWithMaxCount</key><integer>10</integer>
                <key>NSExtensionActivationSupportsFileWithMaxCount</key><integer>10</integer>
                <key>NSExtensionActivationSupportsImagesWithMaxCount</key><integer>10</integer>
                <key>NSExtensionActivationSupportsMoviesWithMaxCount</key><integer>5</integer>
                <key>NSExtensionActivationSupportsText</key><true/>
                <key>NSExtensionActivationSupportsWebURLWithMaxCount</key><integer>1</integer>
                <key>NSExtensionActivationSupportsWebPageWithMaxCount</key><integer>1</integer>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.6.1</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>

    <!-- Menu bar app: no Dock icon. -->
    <key>LSUIElement</key><true/>

    <!-- The share extension (Finder right-click → Share → Bridg) drops items
         into a shared inbox and wakes the app through this URL scheme —
         including launching it when it is not running. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.bridg.mac</string>
            <key>CFBundleURLSchemes</key><array><string>bridg</string></array>
        </dict>
    </array>

    <!-- Required on macOS 15+ or Bonjour discovery silently returns nothing. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Bridg connects to your phone over your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_bridg._tcp</string></array>

    <!-- Click-to-call dials through the phone over Bluetooth Hands-Free.
         Without this key macOS kills the app on its first Bluetooth call. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Bridg asks your paired phone to place calls you start on the Mac.</string>
</dict>
</plist>
PLIST

# Sign with a real identity if one exists — macOS denies notifications outright
# to ad-hoc-signed apps ("Notifications are not allowed for this application"),
# and PlugInKit refuses to load extensions from ad-hoc-signed bundles. Falls
# back to ad-hoc, which is enough for Local Network but not notifications/share
# menu. `|| true` — no matching identity makes grep exit 1, which under `set -eo
# pipefail` would kill the script (e.g. on a CI runner with no signing certs).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"' || true)"

# --- Sign the share extension first, with its entitlements ------------------
# PlugInKit only loads sandboxed extensions ("plug-ins must be sandboxed").
# The appex drops shared items INSIDE its own sandbox container (writes there
# are always allowed); the app is not sandboxed and reads that container path
# directly. A temporary-exception entitlement for the real home directory does
# not work here: it is not honored for code signed without a provisioning
# profile, so every write to the real inbox was silently denied.
ENTITLEMENTS="build/BridgShare.entitlements"
mkdir -p build
cat > "$ENTITLEMENTS" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
ENTS

codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
    --sign "${IDENTITY:--}" "$APPEX" 2>/dev/null \
    || echo "warning: codesign failed on the share extension"

# --- Then sign the outer app ------------------------------------------------
# Deliberately NOT --deep: deep signing re-seals nested bundles without
# entitlements, which would strip the appex's sandbox and break it.
codesign --force --sign "${IDENTITY:--}" "$APP" 2>/dev/null \
    || echo "warning: codesign failed (app may not get network/notification permission)"
echo "signed with: ${IDENTITY:-ad-hoc}"

echo "Built $(pwd)/$APP"
echo "Note: after (re)installing to /Applications, the Share menu may need a kick
when the app is already registered: run 'pluginkit -a "$APP"' or log out and back in."

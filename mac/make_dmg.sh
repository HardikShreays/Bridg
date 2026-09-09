#!/bin/bash
# Builds a release Bridg.app and packages it as build/Bridg.dmg for download.
#
# For a build OTHER people can open without Gatekeeper blocking it, you need a
# paid Apple Developer account and these env vars set:
#   DEVID   - "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE - name of a stored notarytool keychain profile
#                    (create once: xcrun notarytool store-credentials NOTARY_PROFILE
#                     --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>)
# Without them the script still makes a .dmg, but users must right-click > Open
# and dismiss a scary warning.
set -euo pipefail
cd "$(dirname "$0")"

./make_app.sh release
APP="build/Bridg.app"
DMG="build/Bridg.dmg"

if [[ -n "${DEVID:-}" ]]; then
    echo "signing with Developer ID: $DEVID"
    codesign --force --deep --options runtime --timestamp --sign "$DEVID" "$APP"
fi

rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Bridg -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ -n "${DEVID:-}" ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "notarizing via keychain profile (a few minutes)..."
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
        echo "notarizing via apple-id (a few minutes)..."
        xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" \
            --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "Built $(pwd)/$DMG"

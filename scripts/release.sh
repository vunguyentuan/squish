#!/bin/bash
# Signs build/Squish.app with a Developer ID, notarizes it, staples the ticket and zips it.
#   SIGN_IDENTITY   codesign identity (default: the "Developer ID Application" certificate)
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials …)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Squish.app"
ZIP="$ROOT/build/Squish.zip"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-notary-profile}"

[ -d "$APP" ] || { echo "Run make app first"; exit 1; }

echo "▸ Signing ($IDENTITY)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "▸ Notarizing (this takes a minute or two)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $(du -h "$ZIP" | cut -f1)  $ZIP"

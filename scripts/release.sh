#!/bin/bash
# Signs build/Squish.app with a Developer ID, packs it into a DMG with create-dmg
# (npm install --global create-dmg), notarizes the DMG and staples the ticket.
#   SIGN_IDENTITY   codesign identity (default: the "Developer ID Application" certificate)
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials …)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Squish.app"
DMG="$ROOT/build/Squish.dmg"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-notary-profile}"

[ -d "$APP" ] || { echo "Run make app first"; exit 1; }
command -v create-dmg >/dev/null || { echo "Install create-dmg: npm install --global create-dmg"; exit 1; }

echo "▸ Signing ($IDENTITY)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "▸ Creating DMG"
rm -f "$DMG"
create-dmg "$APP" "$ROOT/build" --overwrite --no-version-in-filename \
  --identity="$IDENTITY" --dmg-title="Squish"
codesign --verify "$DMG"

echo "▸ Notarizing (this takes a minute or two)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "✓ $(du -h "$DMG" | cut -f1)  $DMG"

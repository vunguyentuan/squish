#!/bin/bash
# Signs build/Squish.app with a Developer ID, packs it into a DMG with create-dmg
# (npm install --global create-dmg), notarizes the DMG, staples the ticket, and writes
# the Sparkle appcast to site/public/appcast.xml. Release notes come from release-notes/<version>.md.
#   SIGN_IDENTITY   codesign identity (default: the "Developer ID Application" certificate)
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials …)
#   SPARKLE_ACCOUNT keychain account holding the Sparkle EdDSA key (default: squish)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Squish.app"
DMG="$ROOT/build/Squish.dmg"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-notary-profile}"
SPARKLE_BIN="$ROOT/App/.build/artifacts/sparkle/Sparkle/bin"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-squish}"

[ -d "$APP" ] || { echo "Run make app first"; exit 1; }
command -v create-dmg >/dev/null || { echo "Install create-dmg: npm install --global create-dmg"; exit 1; }

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")"
NOTES="$ROOT/release-notes/$VERSION.md"
[ -f "$NOTES" ] || { echo "Write the release notes first: $NOTES"; exit 1; }

echo "▸ Signing $VERSION ($IDENTITY)"
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
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

echo "▸ Writing appcast"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"
cat > "$ROOT/site/public/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Squish</title>
    <link>https://squish.madebyvu.com/appcast.xml</link>
    <item>
      <title>Squish $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/vunguyentuan/squish/releases</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
      <enclosure url="https://github.com/vunguyentuan/squish/releases/download/v$VERSION/Squish.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF

echo "✓ $(du -h "$DMG" | cut -f1)  $DMG — publish with make publish"

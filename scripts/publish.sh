#!/bin/bash
# Publishes what make release built: the GitHub release with Squish.dmg, then the site,
# which carries the appcast. In that order, so apps never see an update they can't download yet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$ROOT/build/Squish.dmg"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/build/Squish.app/Contents/Info.plist")"
NOTES="$ROOT/release-notes/$VERSION.md"

[ -f "$DMG" ] || { echo "Run make release first"; exit 1; }
grep -q "v$VERSION/Squish.dmg" "$ROOT/site/public/appcast.xml" || { echo "appcast.xml isn't for $VERSION; run make release"; exit 1; }

echo "▸ GitHub release v$VERSION"
{
    echo '**Download `Squish.dmg`, open it, and drag Squish to Applications.** Signed with a Developer ID and notarized by Apple.'
    echo
    cat "$NOTES"
    echo
    echo 'Requires macOS 26 Tahoe or later on Apple Silicon.'
} | gh release create "v$VERSION" "$DMG" --title "Squish ${VERSION%.0}" --notes-file - --target main

echo "▸ Deploying site and appcast"
(cd "$ROOT/site" && npx wrangler deploy)
echo "✓ Squish $VERSION is live"

#!/bin/bash
# Builds the Rust engine, the SwiftUI app, and assembles build/Squish.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Squish.app"
export MACOSX_DEPLOYMENT_TARGET=26.0

echo "▸ Building Rust engine"
cargo build --release --manifest-path "$ROOT/core/Cargo.toml"

echo "▸ Building SwiftUI app ($CONFIG)"
# The compiler also writes the App Intents' compile-time values, which Xcode would normally
# turn into Metadata.appintents (what Shortcuts reads) — SwiftPM doesn't, so we do it below.
INTENTS="$ROOT/build/intents"
mkdir -p "$INTENTS"
CONST_VALUES="$INTENTS/Squish.swiftconstvalues"
SWIFT_FLAGS=(
    -Xswiftc -emit-const-values-path -Xswiftc "$CONST_VALUES"
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$ROOT/scripts/appintents-protocols.json"
)
[ "$CONFIG" = "release" ] || SWIFT_FLAGS+=(-Xswiftc -wmo)
# Hide the harmless "built for newer macOS" linker noise from Homebrew's prebuilt Rust std,
# but still fail the build when swift build fails.
set -o pipefail
swift build --package-path "$ROOT/App" -c "$CONFIG" "${SWIFT_FLAGS[@]}" 2>&1 | { grep -v "was built for newer 'macOS' version" || true; }
BIN="$(swift build --package-path "$ROOT/App" -c "$CONFIG" --show-bin-path)/Squish"
[ -x "$BIN" ] || { echo "Swift build failed"; exit 1; }

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Squish"
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/App/Resources/Info.plist" "$APP/Contents/Info.plist"

ICON_CACHE="$ROOT/build/AppIcon.icns"
if [ ! -f "$ICON_CACHE" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICON_CACHE" ]; then
    echo "▸ Rendering icon"
    WORK="$(mktemp -d)"
    swift "$ROOT/scripts/make-icon.swift" "$WORK/icon.png"
    ICONSET="$WORK/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICON_CACHE"
    rm -rf "$WORK"
fi
cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
xcrun xcstringstool compile "$ROOT/App/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources"

echo "▸ Generating App Intents metadata"
if [ -f "$CONST_VALUES" ]; then
    find "$ROOT/App/Sources/Squish" -name '*.swift' > "$INTENTS/sources.txt"
    echo "$CONST_VALUES" > "$INTENTS/constvalues.txt"
    xcrun appintentsmetadataprocessor \
        --output "$APP/Contents/Resources" \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name Squish \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
        --platform-family macOS \
        --deployment-target 26.0 \
        --target-triple "$(uname -m)-apple-macos26.0" \
        --source-file-list "$INTENTS/sources.txt" \
        --swift-const-vals-list "$INTENTS/constvalues.txt" \
        --binary-file "$BIN" \
        --force --quiet-warnings 2>&1 | { grep -iE "error|warning" || true; }
    [ -d "$APP/Contents/Resources/Metadata.appintents" ] || { echo "App Intents metadata missing"; exit 1; }
else
    echo "  (no const values: the build was up to date; run make clean for Shortcuts metadata)"
fi

if [ "$CONFIG" = "release" ]; then strip -x "$APP/Contents/MacOS/Squish"; fi
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
echo "✓ $(du -sh "$APP" | cut -f1)  $APP"

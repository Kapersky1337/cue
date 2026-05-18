#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "→ Compiling release build…"
swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)
APP_DIR="build/Cue.app"

echo "→ Assembling Cue.app bundle…"
rm -rf "$APP_DIR"
rm -rf "build/Caret.app"  # remove old name if present
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/Caret" "$APP_DIR/Contents/MacOS/Caret"
cp Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f "Sources/Caret/Resources/Caret.icns" ]; then
    cp "Sources/Caret/Resources/Caret.icns" "$APP_DIR/Contents/Resources/Caret.icns"
fi

echo "→ Ad-hoc code signing…"
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "✓ Built: $APP_DIR"
echo ""
echo "  open $APP_DIR"

#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "→ Compiling release build…"
# BIN_PATH must use the SAME arch flags as the build: universal and single-arch
# builds land in different directories, and mixing them packages a stale binary.
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN_PATH=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    swift build -c release
    BIN_PATH=$(swift build -c release --show-bin-path)
fi
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

# Prefer the Developer ID cert: a STABLE signing identity means macOS keeps the
# Accessibility grant across rebuilds. Ad-hoc signing (-) mints a new identity every
# build, which is why the permission checkbox goes stale and the hotkey dies.
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
    echo "→ Signing with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
else
    echo "→ Ad-hoc code signing (no Developer ID found — permission will go stale on rebuilds)…"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo ""
echo "✓ Built: $APP_DIR"
echo ""
echo "  open $APP_DIR"

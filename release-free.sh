#!/bin/bash
# release-free.sh — produces Cue.dmg using ad-hoc signing (no Developer ID needed).
#
# Usage:
#   ./release-free.sh           # uses version from Info.plist
#   ./release-free.sh 0.10.0    # override version
#
# What this gives you:
#   - Universal binary (Apple Silicon + Intel)
#   - Ad-hoc signed (no $99 Apple Developer Program)
#   - DMG with drag-to-Applications layout
#
# What it does NOT give you:
#   - Gatekeeper acceptance. First-time users see "Cue can't be opened because it is
#     from an unidentified developer." They must right-click → Open the first launch.
#     Document this clearly on your download page.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)}"
DMG_NAME="Cue-$VERSION.dmg"

echo "→ Building release, version $VERSION"
# Try universal (arm64 + x86_64). Requires full Xcode; falls back to host arch if not available.
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    UNIVERSAL=true
    BIN_PATH=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    echo "  (full Xcode not installed — building for current architecture only)"
    swift build -c release
    UNIVERSAL=false
    BIN_PATH=$(swift build -c release --show-bin-path)
fi

echo "→ Assembling Cue.app bundle"
rm -rf dist
mkdir -p "dist/Cue.app/Contents/MacOS"
mkdir -p "dist/Cue.app/Contents/Resources"
cp "$BIN_PATH/Caret" "dist/Cue.app/Contents/MacOS/Caret"
cp Info.plist "dist/Cue.app/Contents/Info.plist"
[ -f "Sources/Caret/Resources/Caret.icns" ] && cp "Sources/Caret/Resources/Caret.icns" "dist/Cue.app/Contents/Resources/Caret.icns"

# Bump version in the bundled plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "dist/Cue.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "dist/Cue.app/Contents/Info.plist"

echo "→ Ad-hoc signing"
codesign --force --deep --sign - "dist/Cue.app"

echo "→ Staging DMG contents"
DMG_SRC="dist/dmg-src"
rm -rf "$DMG_SRC"
mkdir -p "$DMG_SRC"
cp -R "dist/Cue.app" "$DMG_SRC/"
# Drag-to-Applications shortcut
ln -s /Applications "$DMG_SRC/Applications"

echo "→ Creating DMG ($DMG_NAME)"
hdiutil create \
  -volname "Cue $VERSION" \
  -srcfolder "$DMG_SRC" \
  -ov \
  -format UDZO \
  "dist/$DMG_NAME"

echo ""
echo "✓ Released: dist/$DMG_NAME"
echo "  Size:    $(du -h dist/$DMG_NAME | awk '{print $1}')"
echo "  SHA256:  $(shasum -a 256 dist/$DMG_NAME | awk '{print $1}')"
echo ""
echo "  Binary architecture:"
file dist/Cue.app/Contents/MacOS/Caret | sed 's/^/    /'
if [ "$UNIVERSAL" = "false" ]; then
    echo ""
    echo "  ⚠  This build is Apple Silicon only. Intel Mac users won't be able to run it."
    echo "     For universal (Intel + Apple Silicon), install full Xcode then rerun."
fi
echo ""
echo "  Next:"
echo "    1. Upload dist/$DMG_NAME to GitHub Releases (or any host)"
echo "    2. Link from your site"
echo "    3. On your download page, instruct first-time users:"
echo "         'Right-click Cue.app → Open → Open Anyway' on first launch only"

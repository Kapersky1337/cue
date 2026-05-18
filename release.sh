#!/bin/bash
# release.sh — produces a signed, notarized, stapled Cue.dmg ready for distribution.
#
# Usage:
#   ./release.sh           # uses version from Info.plist
#   ./release.sh 0.10.1    # bumps to 0.10.1 in the bundle and the DMG filename
#
# What this gives you:
#   - Signed with your Developer ID Application certificate
#   - Hardened Runtime enabled (required for notarization)
#   - Notarized by Apple
#   - Stapled (so Gatekeeper accepts without an internet check)
#   - Packaged as a DMG with drag-to-Applications layout
#   - Users see zero warnings on first launch

set -euo pipefail
cd "$(dirname "$0")"

# === Cue's signing config (set up via Apple Developer Program) ===
IDENTITY="Developer ID Application: Zeel Patel (9Y3P8V5P7R)"
KEYCHAIN_PROFILE="cue-notarize"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)}"
# =================================================================

APP_DIR="dist/Cue.app"
DMG="dist/Cue-$VERSION.dmg"

echo "→ Building release v$VERSION"
# Try Universal (arm64 + x86_64). Falls back to current arch if full Xcode isn't installed.
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN_PATH=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
    UNIVERSAL=true
else
    echo "  (full Xcode not detected — building for current architecture only)"
    swift build -c release
    BIN_PATH=$(swift build -c release --show-bin-path)
    UNIVERSAL=false
fi

echo "→ Assembling Cue.app bundle"
rm -rf dist
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH/Caret" "$APP_DIR/Contents/MacOS/Caret"
cp Info.plist "$APP_DIR/Contents/Info.plist"
[ -f "Sources/Caret/Resources/Caret.icns" ] && cp "Sources/Caret/Resources/Caret.icns" "$APP_DIR/Contents/Resources/Caret.icns"

# Bump version inside the bundled Info.plist (without modifying the source)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist"

echo "→ Signing with Hardened Runtime + secure timestamp"
codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP_DIR"

echo "→ Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "→ Zipping for notarization upload"
TMP_ZIP="dist/notarize-app.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$TMP_ZIP"

echo "→ Submitting app to Apple notary service (typically 1–3 min)"
xcrun notarytool submit "$TMP_ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait
rm "$TMP_ZIP"

echo "→ Stapling notarization ticket to the .app"
xcrun stapler staple "$APP_DIR"

echo "→ Building DMG"
DMG_SRC="dist/dmg-src"
rm -rf "$DMG_SRC"
mkdir -p "$DMG_SRC"
cp -R "$APP_DIR" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Applications"

hdiutil create \
    -volname "Cue $VERSION" \
    -srcfolder "$DMG_SRC" \
    -ov \
    -format UDZO \
    "$DMG"

rm -rf "$DMG_SRC"

echo "→ Notarizing the DMG itself (so Gatekeeper trusts the downloaded file too)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "→ Stapling notarization ticket to the DMG"
xcrun stapler staple "$DMG"

echo ""
echo "✓ Released: $DMG"
echo "  Size:    $(du -h "$DMG" | awk '{print $1}')"
echo "  SHA256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo ""
echo "  Architecture:"
file "$APP_DIR/Contents/MacOS/Caret" | sed 's/^/    /'
if [ "$UNIVERSAL" = "false" ]; then
    echo ""
    echo "  ⚠  This DMG is Apple Silicon only. Intel users won't be able to run it."
    echo "     For Universal binary (works on every Mac from 2020+):"
    echo "     install Xcode from the App Store, then re-run this script."
fi
echo ""
echo "  Final verification:"
echo "    .app Gatekeeper:"
spctl -a -t open --context context:primary-signature -vv "$APP_DIR" 2>&1 | sed 's/^/      /'
echo "    DMG staple:"
xcrun stapler validate "$DMG" 2>&1 | sed 's/^/      /'
echo ""
echo "  Ready to upload. Users will see zero warnings."

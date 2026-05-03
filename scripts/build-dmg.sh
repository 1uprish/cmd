#!/usr/bin/env bash
set -euo pipefail
# Builds a distributable DMG from the signed .app bundle.
# Requires build-release.sh to have run first.
# Optional environment variables:
#   SIGN_DMG          Set to 1 to codesign the DMG.
#   SIGNING_IDENTITY  Exact Developer ID Application identity used for DMG signing.
# Usage:
#   ./scripts/build-dmg.sh
#   SIGN_DMG=1 SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-dmg.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$REPO_ROOT/build/cmd.app"
SIGN_DMG="${SIGN_DMG:-0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

# ---------------------------------------------------------------------------
# 1. Verify the .app bundle exists
# ---------------------------------------------------------------------------
if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: $BUNDLE not found."
    echo "       Run ./scripts/build-release.sh first to build the app bundle."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Variables
# ---------------------------------------------------------------------------
VERSION=$(defaults read "$BUNDLE/Contents/Info" CFBundleShortVersionString)
DMG_NAME="cmd-${VERSION}.dmg"
DMG_PATH="$REPO_ROOT/build/$DMG_NAME"
VOL_NAME="cmd"
RW_DMG="$REPO_ROOT/build/${VOL_NAME}-rw.dmg"
MOUNT_DIR="$REPO_ROOT/build/dmg-mount"
BACKGROUND_NAME="dmg-background.png"

echo "==> Building DMG for cmd ${VERSION}..."
echo "    Bundle: $BUNDLE"
echo "    Output: $DMG_PATH"

# ---------------------------------------------------------------------------
# 3. Create temp staging directory
# ---------------------------------------------------------------------------
STAGING=$(mktemp -d)
echo "    Staging dir: $STAGING"

# ---------------------------------------------------------------------------
# 4. Copy .app into staging
# ---------------------------------------------------------------------------
echo "    Copying cmd.app into staging..."
ditto "$BUNDLE" "$STAGING/cmd.app"

# ---------------------------------------------------------------------------
# 5. Symlink /Applications
# ---------------------------------------------------------------------------
echo "    Creating /Applications symlink..."
ln -s /Applications "$STAGING/Applications"

# ---------------------------------------------------------------------------
# 6. Add the custom Finder background
# ---------------------------------------------------------------------------
echo "    Rendering premium DMG background..."
mkdir -p "$STAGING/.background"
"$SCRIPT_DIR/make-dmg-background.swift" "$STAGING/.background/$BACKGROUND_NAME"
chflags hidden "$STAGING/.background" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Create a read-write DMG so Finder layout metadata can be saved
# ---------------------------------------------------------------------------
echo "==> Creating styled read-write DMG..."
rm -f "$RW_DMG" "$DMG_PATH"
rm -rf "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "$RW_DMG" >/dev/null

echo "==> Mounting DMG to apply Finder layout..."
hdiutil attach "$RW_DMG" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" >/dev/null

cleanup_mount() {
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    rm -rf "$MOUNT_DIR"
    rm -rf "$STAGING"
}
trap cleanup_mount EXIT

echo "==> Styling Finder window..."
osascript <<OSA
tell application "Finder"
    set dmgFolder to POSIX file "$MOUNT_DIR" as alias
    set backgroundImage to POSIX file "$MOUNT_DIR/.background/$BACKGROUND_NAME" as alias
    open dmgFolder
    set dmgWindow to container window of dmgFolder
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    set sidebar width of dmgWindow to 0
    set bounds of dmgWindow to {180, 120, 900, 580}
    set theOptions to icon view options of dmgWindow
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 96
    set background picture of theOptions to backgroundImage
    set position of item "cmd.app" of dmgFolder to {180, 230}
    set position of item "Applications" of dmgFolder to {540, 230}
    close dmgWindow
    open dmgFolder
    update dmgFolder without registering applications
    delay 1
end tell
OSA

sync
hdiutil detach "$MOUNT_DIR" -quiet
rm -rf "$MOUNT_DIR"

# ---------------------------------------------------------------------------
# 8. Convert to a compressed distributable DMG
# ---------------------------------------------------------------------------
echo "==> Compressing final DMG..."
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"

# ---------------------------------------------------------------------------
# 9. Optionally sign the DMG
# ---------------------------------------------------------------------------
if [[ "$SIGN_DMG" == "1" ]]; then
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(
            security find-identity -v -p codesigning 2>/dev/null \
                | awk -F\" '/Developer ID Application/ { print $2; exit }'
        )"
    fi

    if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
        echo "ERROR: SIGN_DMG=1 requires a real Developer ID Application identity." >&2
        exit 1
    fi

    echo "==> Signing DMG with identity: '$SIGNING_IDENTITY'..."
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --verbose=1 "$DMG_PATH"
    echo "    DMG signature valid."
fi

# ---------------------------------------------------------------------------
# 10. Clean up staging
# ---------------------------------------------------------------------------
rm -rf "$STAGING"
trap - EXIT

# ---------------------------------------------------------------------------
# 11. Verify disk image
# ---------------------------------------------------------------------------
echo "==> Verifying DMG checksum..."
hdiutil verify "$DMG_PATH"

# ---------------------------------------------------------------------------
# 12. Report
# ---------------------------------------------------------------------------
echo ""
echo "DMG ready: $DMG_PATH"
du -sh "$DMG_PATH"
echo "SHA-256:"
shasum -a 256 "$DMG_PATH"

# ---------------------------------------------------------------------------
# 13. Prompt to verify
# ---------------------------------------------------------------------------
echo ""
echo "To verify the DMG, run:"
echo "  open \"$DMG_PATH\""

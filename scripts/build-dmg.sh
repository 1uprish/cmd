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
# 6. Create the DMG
# ---------------------------------------------------------------------------
echo "==> Creating DMG with hdiutil..."
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# ---------------------------------------------------------------------------
# 7. Optionally sign the DMG
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
# 8. Clean up staging
# ---------------------------------------------------------------------------
rm -rf "$STAGING"

# ---------------------------------------------------------------------------
# 9. Verify disk image
# ---------------------------------------------------------------------------
echo "==> Verifying DMG checksum..."
hdiutil verify "$DMG_PATH"

# ---------------------------------------------------------------------------
# 10. Report
# ---------------------------------------------------------------------------
echo ""
echo "DMG ready: $DMG_PATH"
du -sh "$DMG_PATH"
echo "SHA-256:"
shasum -a 256 "$DMG_PATH"

# ---------------------------------------------------------------------------
# 11. Prompt to verify
# ---------------------------------------------------------------------------
echo ""
echo "To verify the DMG, run:"
echo "  open \"$DMG_PATH\""

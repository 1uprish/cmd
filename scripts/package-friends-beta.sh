#!/usr/bin/env bash
# package-friends-beta.sh — Free/private beta package without Apple Developer ID.
#
# This creates an ad-hoc signed DMG intended only for trusted friends.
# It cannot pass Gatekeeper like a notarised Developer ID build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

"$SCRIPT_DIR/build-release.sh"

BUNDLE="$REPO_ROOT/build/cmd.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist")"
DMG_PATH="$REPO_ROOT/build/cmd-${VERSION}-friends-beta.dmg"
STAGING="$(mktemp -d)"

cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

echo "==> Building friends beta DMG..."
echo "    Output: $DMG_PATH"

ditto "$BUNDLE" "$STAGING/cmd.app"
ln -s /Applications "$STAGING/Applications"
cp "$REPO_ROOT/FRIENDS_BETA_INSTALL.txt" "$STAGING/READ ME FIRST.txt"

hdiutil create \
    -volname "cmd Friends Beta" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

echo "==> Verifying DMG checksum..."
hdiutil verify "$DMG_PATH"

echo ""
echo "SUCCESS: Friends beta DMG ready:"
echo "         $DMG_PATH"
echo ""
echo "SHA-256:"
shasum -a 256 "$DMG_PATH"
echo ""
echo "Important: this is ad-hoc signed and not notarised. Send it only to trusted"
echo "friends along with the included READ ME FIRST.txt."

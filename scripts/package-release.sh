#!/usr/bin/env bash
# package-release.sh — Full professional release pipeline for cmd.
#
# Produces a Developer ID signed, notarised, stapled, DMG-packaged release.
#
# Required:
#   A valid Developer ID Application certificate in the login keychain.
#
# Authentication, choose one:
#   NOTARY_PROFILE   notarytool keychain profile created with:
#                    xcrun notarytool store-credentials cmdNotary
#   or:
#   APPLE_ID         Apple ID used for notarisation
#   TEAM_ID          10-character Apple Developer Team ID
#   APP_PASSWORD     App-specific password
#
# Optional:
#   SIGNING_IDENTITY Exact Developer ID Application identity. If omitted,
#                    the first installed Developer ID Application identity
#                    is used.
#
# Usage:
#   NOTARY_PROFILE=cmdNotary ./scripts/package-release.sh
#   APPLE_ID=you@example.com TEAM_ID=XXXXXXXXXX APP_PASSWORD=xxxx-xxxx-xxxx-xxxx ./scripts/package-release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_PATH="$REPO_ROOT/build/CMD.app"

resolve_signing_identity() {
    if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
        SIGNING_IDENTITY="$(
            security find-identity -v -p codesigning 2>/dev/null \
                | awk -F\" '/Developer ID Application/ { print $2; exit }'
        )"
        export SIGNING_IDENTITY
    fi

    if [[ -z "${SIGNING_IDENTITY:-}" || "$SIGNING_IDENTITY" == "-" ]]; then
        cat >&2 <<'EOF'
ERROR: A real Developer ID Application certificate is required.

Install one via Xcode Settings -> Accounts -> Manage Certificates, then run:
  security find-identity -v -p codesigning
EOF
        exit 1
    fi
}

validate_notary_auth() {
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        return
    fi

    local missing=()
    [[ -z "${APPLE_ID:-}" ]] && missing+=("APPLE_ID")
    [[ -z "${TEAM_ID:-}" ]] && missing+=("TEAM_ID")
    [[ -z "${APP_PASSWORD:-}" ]] && missing+=("APP_PASSWORD")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Notarisation credentials are missing:" >&2
        for item in "${missing[@]}"; do
            echo "  - $item" >&2
        done
        echo "" >&2
        echo "Preferred setup:" >&2
        echo "  xcrun notarytool store-credentials cmdNotary" >&2
        echo "  NOTARY_PROFILE=cmdNotary ./scripts/package-release.sh" >&2
        exit 1
    fi
}

manifest_value() {
    /usr/libexec/PlistBuddy -c "Print $1" "$BUNDLE_PATH/Contents/Info.plist"
}

resolve_signing_identity
validate_notary_auth

echo "==> Professional release pipeline"
echo "    Signing identity: $SIGNING_IDENTITY"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "    Notary profile:   $NOTARY_PROFILE"
else
    echo "    Notary account:   $APPLE_ID / $TEAM_ID"
fi
echo ""

"$SCRIPT_DIR/build-release.sh"

TARGET_PATH="$BUNDLE_PATH" "$SCRIPT_DIR/notarise.sh"

VERSION="$(manifest_value CFBundleShortVersionString)"
BUILD="$(manifest_value CFBundleVersion)"

SIGN_DMG=1 "$SCRIPT_DIR/build-dmg.sh"

DMG_PATH="$REPO_ROOT/build/CMD-${VERSION}.dmg"
TARGET_PATH="$DMG_PATH" "$SCRIPT_DIR/notarise.sh"

MANIFEST_PATH="$REPO_ROOT/build/CMD-${VERSION}-release-manifest.txt"
{
    echo "CMD release manifest"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "App:       $BUNDLE_PATH"
    echo "DMG:       $DMG_PATH"
    echo "Version:   $VERSION"
    echo "Build:     $BUILD"
    echo "Bundle ID: $(manifest_value CFBundleIdentifier)"
    echo "Signer:    $SIGNING_IDENTITY"
    echo "Size:      $(stat -f%z "$DMG_PATH") bytes"
    echo "SHA-256:   $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
} > "$MANIFEST_PATH"

echo ""
echo "SUCCESS: Professional release package is ready."
echo "         DMG:      $DMG_PATH"
echo "         Manifest: $MANIFEST_PATH"

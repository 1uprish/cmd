#!/usr/bin/env bash
# notarise.sh — Notarise and staple cmd.app or cmd.dmg for direct distribution.
#
# Required:
#   TARGET_PATH      Signed .app bundle or .dmg to notarise.
#                    BUNDLE_PATH is still accepted for compatibility.
#
# Authentication, choose one:
#   NOTARY_PROFILE   notarytool keychain profile created with
#                    `xcrun notarytool store-credentials`
#   or:
#   APPLE_ID         Apple ID used for notarisation (e.g. you@example.com)
#   TEAM_ID          10-character Apple Developer Team ID
#   APP_PASSWORD     App-specific password generated at appleid.apple.com
#
# Usage:
#   TARGET_PATH=./build/cmd.app \
#   NOTARY_PROFILE=cmdNotary \
#   ./scripts/notarise.sh
#
#   TARGET_PATH=./build/cmd.app \
#   APPLE_ID=you@example.com \
#   TEAM_ID=XXXXXXXXXX \
#   APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#   ./scripts/notarise.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Validate required environment variables
# ---------------------------------------------------------------------------
TARGET_PATH="${TARGET_PATH:-${BUNDLE_PATH:-}}"
missing=()
[[ -z "$TARGET_PATH" ]] && missing+=("TARGET_PATH")

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    [[ -z "${APPLE_ID:-}" ]] && missing+=("APPLE_ID")
    [[ -z "${TEAM_ID:-}" ]] && missing+=("TEAM_ID")
    [[ -z "${APP_PASSWORD:-}" ]] && missing+=("APP_PASSWORD")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: The following required environment variables are not set:" >&2
    for var in "${missing[@]}"; do
        echo "  - $var" >&2
    done
    exit 1
fi

if [[ ! -e "$TARGET_PATH" ]]; then
    echo "ERROR: Target not found at '$TARGET_PATH'" >&2
    exit 1
fi

if [[ -d "$TARGET_PATH" && "$TARGET_PATH" != *.app ]]; then
    echo "ERROR: Directory targets must be .app bundles." >&2
    exit 1
fi

SUBMISSION_PATH="$TARGET_PATH"
ZIP_PATH=""

# ---------------------------------------------------------------------------
# 2. Prepare submission
# ---------------------------------------------------------------------------
if [[ -d "$TARGET_PATH" ]]; then
    ZIP_PATH="/tmp/cmd-notarise-$(date +%s).zip"
    SUBMISSION_PATH="$ZIP_PATH"
    echo "==> Zipping app bundle for submission..."
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$TARGET_PATH" "$ZIP_PATH"
    echo "    Created: $ZIP_PATH"
else
    echo "==> Submitting file directly: $TARGET_PATH"
fi

# ---------------------------------------------------------------------------
# 3. Submit to Apple Notary Service and wait for result
# ---------------------------------------------------------------------------
echo "==> Submitting to Apple Notary Service (this may take a few minutes)..."
notary_args=(submit "$SUBMISSION_PATH" --wait)
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary_args+=(--keychain-profile "$NOTARY_PROFILE")
else
    notary_args+=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
fi

if ! xcrun notarytool "${notary_args[@]}"; then
    echo "ERROR: Notarisation submission failed." >&2
    exit 1
fi
echo "    Notarisation succeeded."

# ---------------------------------------------------------------------------
# 4. Staple the notarisation ticket
# ---------------------------------------------------------------------------
echo "==> Stapling notarisation ticket..."
if ! xcrun stapler staple "$TARGET_PATH"; then
    echo "ERROR: Stapling failed. The app was notarised but the ticket" >&2
    echo "       could not be attached. Check your network connection and" >&2
    echo "       try running: xcrun stapler staple \"$TARGET_PATH\"" >&2
    exit 1
fi
echo "    Stapling succeeded."

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
echo "==> Verifying Gatekeeper acceptance..."
if [[ "$TARGET_PATH" == *.dmg ]]; then
    spctl --assess --type open --verbose "$TARGET_PATH" 2>&1 || {
        echo "WARNING: spctl assessment failed. The DMG may not pass Gatekeeper." >&2
    }
else
    spctl --assess --type execute --verbose "$TARGET_PATH" 2>&1 || {
        echo "WARNING: spctl assessment failed. The app may not pass Gatekeeper." >&2
    }
fi

echo ""
echo "SUCCESS: $TARGET_PATH is notarised and stapled."
echo "         It is ready for direct distribution."

# Clean up temp zip
if [[ -n "$ZIP_PATH" ]]; then
    rm -f "$ZIP_PATH"
fi

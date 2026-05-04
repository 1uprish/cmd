#!/usr/bin/env bash
# build-release.sh — Build, assemble, and sign a release CMD.app bundle.
#
# Optional environment variables:
#   SIGNING_IDENTITY  Exact Developer ID Application identity.
#                     If omitted, the first installed Developer ID Application
#                     identity is used.
#   ALLOW_ADHOC       Set to 1 only for local unsigned testing with
#                     SIGNING_IDENTITY="-".
#   SWIFT_BUILD_SCRATCH_PATH
#                     Optional scratch path for clean builds when .build was
#                     copied from another checkout or has stale module caches.
#
# Usage:
#   ./scripts/build-release.sh
#   SIGNING_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)" \
#     ./scripts/build-release.sh
#   ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"
SWIFT_BUILD_SCRATCH_PATH="${SWIFT_BUILD_SCRATCH_PATH:-}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BUNDLE_PATH="$REPO_ROOT/build/CMD.app"
CONTENTS="$BUNDLE_PATH/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

BINARY_SRC=""
SWIFT_PRODUCTS_DIR="$REPO_ROOT/.build"
INFO_PLIST_SRC="$REPO_ROOT/Sources/ClipLog/Info.plist"
ENTITLEMENTS_SRC="$REPO_ROOT/Sources/ClipLog/Resources/cmd.entitlements"
PRIVACY_SRC="$REPO_ROOT/Sources/ClipLog/Resources/PrivacyInfo.xcprivacy"

resolve_signing_identity() {
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(
            security find-identity -v -p codesigning 2>/dev/null \
                | awk -F\" '/Developer ID Application/ { print $2; exit }'
        )"
    fi

    if [[ -z "$SIGNING_IDENTITY" ]]; then
        cat >&2 <<'EOF'
ERROR: No Developer ID Application signing identity was found.

For a friends-safe macOS release, install a Developer ID Application
certificate from Xcode Settings -> Accounts -> Manage Certificates.

For local testing only, run:
  ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
EOF
        exit 1
    fi

    if [[ "$SIGNING_IDENTITY" == "-" && "$ALLOW_ADHOC" != "1" ]]; then
        cat >&2 <<'EOF'
ERROR: Ad-hoc signing was requested, but ALLOW_ADHOC=1 was not set.

Ad-hoc builds are useful locally, but they are not professional distribution
builds and will not pass Gatekeeper for friends.
EOF
        exit 1
    fi

    if [[ "$SIGNING_IDENTITY" != "-" ]]; then
        if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGNING_IDENTITY\""; then
            echo "ERROR: Signing identity not found in keychain:" >&2
            echo "       $SIGNING_IDENTITY" >&2
            echo "" >&2
            echo "Available identities:" >&2
            security find-identity -v -p codesigning >&2 || true
            exit 1
        fi
    fi
}

find_release_binary() {
    local candidates=(
        "$SWIFT_PRODUCTS_DIR/apple/Products/Release/ClipLog"
        "$SWIFT_PRODUCTS_DIR/arm64-apple-macosx/release/ClipLog"
        "$SWIFT_PRODUCTS_DIR/x86_64-apple-macosx/release/ClipLog"
        "$SWIFT_PRODUCTS_DIR/release/ClipLog"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            BINARY_SRC="$candidate"
            return
        fi
    done

    BINARY_SRC="$(find "$SWIFT_PRODUCTS_DIR" -path '*/release/ClipLog' -type f -perm -111 2>/dev/null | head -n 1 || true)"
    if [[ -z "$BINARY_SRC" ]]; then
        echo "ERROR: Release binary not found after swift build." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Resolve signing identity and build
# ---------------------------------------------------------------------------
resolve_signing_identity

echo "==> Building cmd (release)..."
swift_build_args=(-c release --package-path "$REPO_ROOT")
if [[ -n "$SWIFT_BUILD_SCRATCH_PATH" ]]; then
    SWIFT_PRODUCTS_DIR="$SWIFT_BUILD_SCRATCH_PATH"
    swift_build_args+=(--scratch-path "$SWIFT_BUILD_SCRATCH_PATH")
fi
swift build "${swift_build_args[@]}"
find_release_binary
echo "    Build succeeded."
echo "    Binary: $BINARY_SRC"

# ---------------------------------------------------------------------------
# 2. Assemble .app bundle directory structure
# ---------------------------------------------------------------------------
echo "==> Assembling app bundle at $BUNDLE_PATH ..."
rm -rf "$BUNDLE_PATH"
# Remove stale pre-rename bundles so packaging can never pick up an old,
# structurally invalid app by accident.
rm -rf "$REPO_ROOT/build/cmd.app"
rm -rf "$REPO_ROOT/build/CopyPasta.app"
rm -rf "$REPO_ROOT/build/ClipLog.app"
rm -f "$REPO_ROOT/build"/cmd-*.dmg
rm -f "$REPO_ROOT/build"/cmd-*-release-manifest.txt
rm -f "$REPO_ROOT/build"/CopyPasta-*.dmg
rm -f "$REPO_ROOT/build"/ClipLog-*.dmg
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# ---------------------------------------------------------------------------
# 3. Copy binary
# ---------------------------------------------------------------------------
echo "    Copying binary..."
ditto "$BINARY_SRC" "$MACOS_DIR/cmd"
chmod +x "$MACOS_DIR/cmd"

# ---------------------------------------------------------------------------
# 4. Copy Info.plist
# ---------------------------------------------------------------------------
echo "    Copying Info.plist..."
cp "$INFO_PLIST_SRC" "$CONTENTS/Info.plist"

# ---------------------------------------------------------------------------
# 5. Copy PrivacyInfo.xcprivacy into Contents/Resources/
# ---------------------------------------------------------------------------
echo "    Copying PrivacyInfo.xcprivacy..."
cp "$PRIVACY_SRC" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"

if [ -f "$REPO_ROOT/Sources/ClipLog/Resources/AppIcon.icns" ]; then
    echo "    Copying AppIcon.icns..."
    cp "$REPO_ROOT/Sources/ClipLog/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# ---------------------------------------------------------------------------
# 6. Code-sign with hardened runtime
# ---------------------------------------------------------------------------
echo "==> Signing bundle with identity: '$SIGNING_IDENTITY'..."
codesign_args=(
    --force \
    --deep \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS_SRC" \
    --options runtime \
    --generate-entitlement-der
)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign_args+=(--timestamp)
fi
codesign \
    "${codesign_args[@]}" \
    "$BUNDLE_PATH"
echo "    Signing succeeded."

# ---------------------------------------------------------------------------
# 7. Verify signature
# ---------------------------------------------------------------------------
echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=1 "$BUNDLE_PATH"
echo "    Signature valid."

# ---------------------------------------------------------------------------
# 8. Gatekeeper assessment for production signatures
# ---------------------------------------------------------------------------
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "==> Clearing quarantine attribute for local ad-hoc build..."
    xattr -rc "$BUNDLE_PATH" 2>/dev/null || true
    echo "    Done."
else
    echo "==> Running Gatekeeper assessment..."
    spctl --assess --type execute --verbose=2 "$BUNDLE_PATH" || {
        echo "    Gatekeeper assessment will pass only after notarisation/stapling." >&2
    }
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "SUCCESS: Bundle ready at:"
echo "         $BUNDLE_PATH"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "         Signing: ad-hoc local testing only"
else
    echo "         Signing: $SIGNING_IDENTITY"
fi
echo ""
echo "Next steps:"
echo "  1. Test locally: open \"$BUNDLE_PATH\""
echo "  2. Notarise:     TARGET_PATH=\"$BUNDLE_PATH\" \\"
echo "                   NOTARY_PROFILE=cmdNotary \\"
echo "                   \"$REPO_ROOT/scripts/notarise.sh\""
echo "  3. Full release: NOTARY_PROFILE=cmdNotary \\"
echo "                   \"$REPO_ROOT/scripts/package-release.sh\""

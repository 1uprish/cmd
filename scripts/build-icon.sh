#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$REPO_ROOT/scripts/AppIcon.iconset"
ICNS_OUT="$REPO_ROOT/Sources/ClipLog/Resources/AppIcon.icns"
echo "==> Rendering ⌘ icon..."
swift "$REPO_ROOT/scripts/make-icon.swift" "$ICONSET"
echo "==> Compiling .icns..."
iconutil -c icns "$ICONSET" -o "$ICNS_OUT"
echo "✅ AppIcon.icns → $ICNS_OUT"

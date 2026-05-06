#!/usr/bin/env bash
set -euo pipefail

# collect-diagnostics.sh — package non-content CMD diagnostics for support.
#
# This intentionally does not copy the clipboard database or media directory.
# It only captures app metadata, CMD's structured diagnostics log, and filtered
# macOS logs around the app process.

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${TMPDIR:-/tmp}/cmd-diagnostics-$STAMP"
ZIP_PATH="$HOME/Desktop/cmd-diagnostics-$STAMP.zip"

mkdir -p "$OUT_DIR"

{
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "== macOS =="
    sw_vers || true
    echo
    echo "== Hardware =="
    uname -a || true
    sysctl -n machdep.cpu.brand_string 2>/dev/null || true
    echo
    echo "== Running CMD processes =="
    ps -axo pid,pcpu,pmem,rss,etime,command | grep -E '/Applications/CMD.app|/Applications/cmd.app|[C]lipLog' || true
    echo
    echo "== Installed app =="
    if [ -d /Applications/CMD.app ]; then
        stat -f '%Sm %N' /Applications/CMD.app /Applications/CMD.app/Contents/MacOS/cmd 2>/dev/null || true
        /usr/libexec/PlistBuddy \
            -c 'Print :CFBundleIdentifier' \
            -c 'Print :CFBundleShortVersionString' \
            -c 'Print :CFBundleVersion' \
            /Applications/CMD.app/Contents/Info.plist 2>/dev/null || true
        codesign -dv --verbose=4 /Applications/CMD.app 2>&1 | sed -n '1,120p' || true
    else
        echo "/Applications/CMD.app not found"
    fi
} > "$OUT_DIR/system.txt"

LOG_DIR="$HOME/Library/Application Support/cmd/Diagnostics"
if [ -f "$LOG_DIR/cmd.log" ]; then
    cp "$LOG_DIR/cmd.log" "$OUT_DIR/cmd.log"
else
    echo "No CMD diagnostics log found at $LOG_DIR/cmd.log" > "$OUT_DIR/cmd.log"
fi

log show --style compact --last 6h \
    --predicate 'process == "cmd" || process == "CMD" || eventMessage CONTAINS[c] "com.cmd" || eventMessage CONTAINS[c] "CMD" || eventMessage CONTAINS[c] "pasteboard" || eventMessage CONTAINS[c] "TCC" || eventMessage CONTAINS[c] "AX"' \
    > "$OUT_DIR/macos-filtered.log" 2>&1 || true

/usr/bin/zip -qry "$ZIP_PATH" -j "$OUT_DIR"
rm -rf "$OUT_DIR"

echo "$ZIP_PATH"

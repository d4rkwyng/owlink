#!/bin/bash
# Command palette check: View › Command Palette (⇧⌘P) driven with real key
# events (CEDRIC_CHECK=palette, Sources/CedricApp/PaletteCheck.swift). Types
# a query into the palette, moves with ↓, runs the row with Return and
# checks the command ran; also Esc, disabled rows, recent-first, VoiceOver
# announcements, an image tab, and the open time (fails over 50 ms; the
# numbers are printed). Then File › Open Quickly… (⌥⌘O, CEDRIC_CHECK=quickopen,
# QuickOpenCheck.swift) over a folder. Also run by Scripts/tools-check.sh. Throwaway
# session; needs a GUI session (works with the screen locked, without
# the ⇧⌘P event timing).
#
#   Scripts/palette-check.sh [--out DIR] [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-palette-check
APP="dist/Owlink.app"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift ;;
        *) APP=${1%/} ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
mkdir -p "$OUT"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
. Scripts/check-env.sh
cedric_isolate "$W"
set +e
for CHECK in palette quickopen; do
    rm -rf "$W/session"
    env CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$OUT" CEDRIC_CHECK=$CHECK \
        CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
        | grep -E '^check:' | tee "$OUT/$CHECK.txt"
done
set -e
for CHECK in palette quickopen; do
    grep -q "check: done .* 0 failed" "$OUT/$CHECK.txt" || { echo "palette-check: $CHECK FAILED" >&2; exit 1; }
done
echo "palette-check: passed (snapshots in $OUT)"

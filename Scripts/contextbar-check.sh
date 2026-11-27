#!/bin/bash
# Context Bar check: View › Show Context Bar driven with real events
# (CEDRIC_CHECK=contextbar, Sources/CedricApp/ContextBarCheck.swift). On by
# default; the check starts it off (no view built); on, a click on Bold over a selection then ⌘Z,
# ⌘2 on a line, Checkbox on three lines, every other button with its undo,
# the heading pull-down, the preview toggle, VoiceOver labels, keyboard
# focus, light and dark themes, right-to-left, the palette's entries, and
# keystroke timing with the bar hidden and shown (alternating rounds; the
# medians are printed). Also run by Scripts/tools-check.sh. Throwaway
# session; needs a GUI session (works with the screen locked).
#
#   Scripts/contextbar-check.sh [--out DIR] [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-contextbar-check
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
. Scripts/check-env.sh
cedric_require_check_build "$APP"
mkdir -p "$OUT"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cedric_isolate "$W"
set +e
env CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$OUT" CEDRIC_CHECK=contextbar \
    CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E '^check:' | tee "$OUT/contextbar.txt"
set -e
grep -q "check: done .* 0 failed" "$OUT/contextbar.txt" || { echo "contextbar-check: FAILED" >&2; exit 1; }
echo "contextbar-check: passed (snapshots in $OUT)"

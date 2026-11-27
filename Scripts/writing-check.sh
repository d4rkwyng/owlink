#!/bin/bash
# Writing Mode and stats check: View › Writing Mode and the status bar's
# stats popover driven with real events (CEDRIC_CHECK=writing, then
# CEDRIC_CHECK=writingrestore; Sources/CedricApp/WritingCheck.swift), then
# View › Readable Width (CEDRIC_CHECK=readable, ReadableWidthCheck.swift).
# Typewriter scrolling keeps the caret line at the middle while 40 lines
# are typed (one scroll per key at most; Reduce Motion: no animation);
# Focus dims the other paragraphs (the rendering attributes are read
# back), then the other sentences; typing timed with Writing Mode off and
# on; a click on the word count opens the popover with the numbers; a
# word goal typed there; the app quits normally, and a second launch on
# the same session finds the goal and the tab's Writing Mode again, with
# the file on disk untouched. Also run by Scripts/tools-check.sh.
# Throwaway session; needs a GUI session (works with the screen locked).
#
#   Scripts/writing-check.sh [--out DIR] [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-writing-check
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
fail=0
set +e
# 1. Writing Mode, the popover and a goal; quits normally (the session is saved).
env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_CHECK_OUT="$OUT" CEDRIC_CHECK=writing \
    CEDRIC_WRITING_DIR="$W/files" CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 120; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E '^check:' | tee "$OUT/writing.txt"
grep -q "check: done .* 0 failed" "$OUT/writing.txt" || fail=1
# The goal is in the session, not in the file.
if grep -q '"wordGoals"' "$W/session/session.json" 2>/dev/null && grep -q '"words" : 500' "$W/session/session.json"; then
    echo "check: PASS session.json holds the essay's word goal"
else
    echo "check: FAIL session.json holds the essay's word goal"; fail=1
fi
if grep -q 500 "$W/files/essay.md"; then echo "check: FAIL essay.md has no goal in it"; fail=1; else echo "check: PASS essay.md has no goal in it"; fi
# 2. Relaunch on that session.
env -u CEDRIC_NO_RESTORE CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$OUT" CEDRIC_CHECK=writingrestore \
    CEDRIC_WRITING_DIR="$W/files" CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E '^check:' | tee "$OUT/writingrestore.txt"
grep -q "check: done .* 0 failed" "$OUT/writingrestore.txt" || fail=1
# 3. View › Readable Width (CEDRIC_CHECK=readable, ReadableWidthCheck.swift).
rm -rf "$W/session-readable"
env CEDRIC_SESSION_DIR="$W/session-readable" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$OUT" CEDRIC_CHECK=readable \
    CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E '^check:' | tee "$OUT/readable.txt"
grep -q "check: done .* 0 failed" "$OUT/readable.txt" || fail=1
set -e
[ $fail = 0 ] || { echo "writing-check: FAILED" >&2; exit 1; }
echo "writing-check: passed (snapshots in $OUT)"

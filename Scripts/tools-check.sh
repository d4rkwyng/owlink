#!/bin/bash
# In-process checks of the editor tools: Open Recent, Text Tools, Find in
# Files, Compare With…, Follow File, Fix Typos… and the rest. Each check launches Cedric with
# CEDRIC_CHECK=<name> (DevChecks.swift): it builds its own files in a temp
# folder, drives the app with real key and mouse NSEvents, prints
# PASS/FAIL lines and writes PNG snapshots. Also lists every menu
# shortcut and fails on a clash. Never touches the real session; the
# recent check puts the recent-documents list back as it found it.
# Needs a GUI session (works with the screen locked).
#
#   Scripts/tools-check.sh [--out DIR] [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-tools-check
APP="dist/Owlink.app"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift ;;
        *) APP=$1 ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
mkdir -p "$OUT"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$OUT"
fail=0
echo "== shortcuts"
env CEDRIC_DUMP_SHORTCUTS=1 "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null | tee "$OUT/shortcuts.txt" | grep -E "CONFLICT|shortcuts:" || fail=1
grep -q "no conflicts" "$OUT/shortcuts.txt" || fail=1
# New Cedric crash reports during the run fail it (CedricApp is the
# unbundled binary, Cedric the app).
crash_reports() { ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -E '^Cedric(App)?-.*\.ips$' | sort; }
crash_reports > "$W/crashes-before.txt"
for c in recent texttool findinfiles compare follow large highlight lineops bookmarks closedtab editedtitle closedraw jsonwhole colours autoedit counts indent print macbasics filterlines encodings cli dropfile spellstep spellopen grammar detachpreview csvpreview csvrownumber git mdlists mdformat mdtable mdpaste langindent mdpreview previewanchor mdsite previewbar outline mdexport cert binary readonly filenotices diskconflict help closenotice menus replaceinfiles folder multicaret statuszoom folding split splittyping defaulteditor settings palette quickopen wikilinks contextbar terminalhere perfsafe; do
    echo "== $c"
    if ! env CEDRIC_CHECK=$c CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
        | grep -E "^check:" | tee "$OUT/$c.txt"; then fail=1; fi
    grep -q "check: done .* 0 failed" "$OUT/$c.txt" || { echo "tools-check: $c FAILED" >&2; fail=1; }
done
# Writing Mode and the stats popover: two launches on one session (a goal kept across a quit).
echo "== writing"
Scripts/writing-check.sh --out "$OUT" "$APP" || { echo "tools-check: writing FAILED" >&2; fail=1; }
# Hot close after a failed session save: needs session saving on.
echo "== closefail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-closefail" CEDRIC_CHECK=closefail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/closefail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/closefail.txt" || { echo "tools-check: closefail FAILED" >&2; fail=1; }
chmod -R u+w "$W" 2>/dev/null || true
echo "== cedric script (dry run: the URLs it would send)"
cli=$(cd "$W" && CEDRIC_DRY_RUN=1 "$OLDPWD/Scripts/cedric" -w a.txt src/x.c:12:5 +3 b.md 'c.py:9:' 2>&1) || fail=1
echo "$cli"
echo "$cli" | grep -q "path=$W/a.txt&wait=.*cedric-wait\\." || { echo "tools-check: cli -w FAILED" >&2; fail=1; }
echo "$cli" | grep -q "path=$W/src/x.c&line=12&col=5&wait=" || { echo "tools-check: cli file:line:col FAILED" >&2; fail=1; }
echo "$cli" | grep -q "path=$W/b.md&line=3&wait=" || { echo "tools-check: cli +line FAILED" >&2; fail=1; }
echo "$cli" | grep -q "path=$W/c.py&line=9&wait=" || { echo "tools-check: cli file:line: FAILED" >&2; fail=1; }
# The token goes in a hand-off file (auth=), never on open's command line.
echo "$cli" | grep -q "token=" && { echo "tools-check: cli token on the command line FAILED" >&2; fail=1; }
echo "$cli" | grep -q "&auth=AUTH" || { echo "tools-check: cli auth= hand-off FAILED" >&2; fail=1; }
# A custom TMPDIR (Nix, tmux): hand-off files still go to the user's temp
# folder, the only one the app accepts (the in-app cli check runs the
# bundled script this way for real and opens its URL without asking).
custom=/tmp/custom.cedric-tools-check$$
mkdir -p "$custom"
user_tmp=$(getconf DARWIN_USER_TEMP_DIR); user_tmp=${user_tmp%/}
cli2=$(cd "$W" && TMPDIR="$custom" CEDRIC_DRY_RUN=1 "$OLDPWD/Scripts/cedric" -w a.txt 2>&1) || fail=1
echo "$cli2"
echo "$cli2" | grep -q "wait=$user_tmp/cedric-wait\\." || { echo "tools-check: cli custom TMPDIR hand-off FAILED" >&2; fail=1; }
ls "$custom" | grep -q . && { echo "tools-check: cli wrote into the custom TMPDIR FAILED" >&2; fail=1; }
rmdir "$custom" 2>/dev/null || true
ls "${TMPDIR:-/tmp}"/cedric-wait.* >/dev/null 2>&1 && echo "note: cedric-wait markers present in TMPDIR (other runs?)"
# (ReportCrash writes a moment after the process dies.)
sleep 3
crash_reports > "$W/crashes-after.txt"
new=$(comm -13 "$W/crashes-before.txt" "$W/crashes-after.txt")
if [ -n "$new" ]; then
    echo "tools-check: new crash reports during the run (another run on this Mac may have made them):" >&2
    echo "$new" | sed 's/^/  /' >&2
    fail=1
else
    echo "== crash reports: none new"
fi
echo "snapshots and logs in $OUT"
exit $fail

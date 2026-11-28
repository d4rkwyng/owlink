#!/bin/bash
# In-process checks of the editor tools: Text Tools, Find in Files,
# Compare With…, Follow File, Fix Typos… and the rest. Each check launches
# Cedric with CEDRIC_CHECK=<name> (DevChecks.swift): it builds its own
# files in a temp folder, drives the app with real key and mouse NSEvents,
# prints PASS/FAIL lines and writes PNG snapshots. Also lists every menu
# shortcut and fails on a clash. Never touches the real session. Needs a
# GUI session (works with the screen locked).
#
#   Scripts/tools-check.sh [--out DIR] [--with-recent] [--with-spellstep] [--skip a,b] [APP]
#                                                   default "dist/Owlink.app"
#
#   --with-recent     also run the Open Recent check. Off by default: it
#                     works on the real per-user recent-documents list (a
#                     check build shares it with the user's Owlink): it
#                     clears it with Clear Menu and replays it. The list is
#                     first saved to cedric-tools-check-recent-snapshot.json
#                     in the user's temp folder (getconf
#                     DARWIN_USER_TEMP_DIR); the file goes
#                     only once the list is back, so a run killed in
#                     between is repaired: every tools-check run that finds
#                     the file puts that list back first (the recentrestore
#                     launch), and again right after a recent check that
#                     died.
#   --with-spellstep  also run spellstep (the spelling panel's Learn Word
#                     and Ignore, on a dictionary of the check's own). Off
#                     by default.
#   --skip a,b        leave out these checks of the default set
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-tools-check
APP="dist/Owlink.app"
WITH_RECENT=0
WITH_SPELLSTEP=0
SKIP=,
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift ;;
        --with-recent) WITH_RECENT=1 ;;
        --with-spellstep) WITH_SPELLSTEP=1 ;;
        --skip) SKIP=",$2,"; shift ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        -*) echo "tools-check.sh: unknown option $1" >&2; exit 2 ;;
        *) APP=$1 ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
. Scripts/check-env.sh
cedric_require_check_build "$APP"
mkdir -p "$OUT"
W=$(mktemp -d)
# The settings check's own AI defaults suite (never the user's standard domain).
# CheckIsolation takes only cedric-check-<letters, digits, hyphens> as a check suite.
SETTINGS_SUITE="cedric-check-tools-settings-$$-$RANDOM"
trap 'rm -rf "$W"; defaults delete "$SETTINGS_SUITE" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$SETTINGS_SUITE.plist"' EXIT
cedric_isolate "$W"
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$OUT"
# The recent check's snapshot of the recent-documents list: a fixed file in
# the user's temp folder (not this run's $W, which the trap removes), so
# the next run finds what a killed run left.
RECENT_SNAP="$(getconf DARWIN_USER_TEMP_DIR)cedric-tools-check-recent-snapshot.json"
export CEDRIC_RECENT_SNAPSHOT="$RECENT_SNAP"
fail=0
recent_restore() {
    [ -f "$RECENT_SNAP" ] || return 0
    echo "== recentrestore (a recent check died with the list cleared: $RECENT_SNAP)"
    env CEDRIC_CHECK=recentrestore perl -e 'alarm 60; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
        | grep -E "^check:" | tee "$OUT/recentrestore.txt" || true
    grep -q "check: done .* 0 failed" "$OUT/recentrestore.txt" && [ ! -f "$RECENT_SNAP" ] \
        || { echo "tools-check: recentrestore FAILED: the saved list is still in $RECENT_SNAP" >&2; fail=1; }
}
recent_restore
CHECKS=""
[ $WITH_RECENT = 1 ] && CHECKS="recent"
echo "== shortcuts"
env CEDRIC_DUMP_SHORTCUTS=1 "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null | tee "$OUT/shortcuts.txt" | grep -E "CONFLICT|shortcuts:" || fail=1
grep -q "no conflicts" "$OUT/shortcuts.txt" || fail=1
# New Cedric crash reports during the run fail it (CedricApp is the
# unbundled binary, Cedric the app).
crash_reports() { ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -E '^Cedric(App)?-.*\.ips$' | sort; }
crash_reports > "$W/crashes-before.txt"
DEFAULT="texttool findinfiles compare follow large highlight lineops bookmarks closedtab editedtitle closedraw jsonwhole colours autoedit counts indent print macbasics filterlines encodings cli dropfile spellopen grammar detachpreview csvpreview csvrownumber git mdlists mdformat mdtable mdpaste langindent mdpreview previewanchor mdsite previewbar outline mdexport mermaidmath cert binary readonly filenotices diskconflict help closenotice menus replaceinfiles folder multicaret statuszoom folding split splittyping defaulteditor settings palette quickopen wikilinks tags contextbar terminalhere perfsafe"
for c in $DEFAULT; do
    if [ $c = spellopen ] && [ $WITH_SPELLSTEP = 1 ]; then CHECKS="$CHECKS spellstep"; fi
    case "$SKIP" in *",$c,"*) echo "== $c (skipped: --skip)"; continue ;; esac
    CHECKS="$CHECKS $c"
done
for c in $CHECKS; do
    echo "== $c"
    # settings: Settings › Cedric on the Built-in engine (its compact Model
    # chooser), with an empty models folder and an AI defaults suite of its
    # own (it saves a model choice there), no inherited model or address,
    # and a spy in place of llama.cpp. The check refuses to run without both.
    extra=()
    if [ $c = settings ]; then
        mkdir -p "$W/models"
        extra=(-u CEDRIC_AI_MODEL -u CEDRIC_AI_URL CEDRIC_AI_BACKEND=builtIn "CEDRIC_MODELS_DIR=$W/models"
               "CEDRIC_AI_DEFAULTS=$SETTINGS_SUITE" CEDRIC_BUILTIN_SPY=1)
    fi
    if ! env ${extra[@]+"${extra[@]}"} CEDRIC_CHECK=$c CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
        | grep -E "^check:" | tee "$OUT/$c.txt"; then fail=1; fi
    grep -q "check: done .* 0 failed" "$OUT/$c.txt" || { echo "tools-check: $c FAILED" >&2; fail=1; }
    [ $c != recent ] || recent_restore
done
[ $WITH_RECENT = 1 ] || echo "== recent (not run: --with-recent)"
[ $WITH_SPELLSTEP = 1 ] || echo "== spellstep (not run: --with-spellstep)"
# Writing Mode and the stats popover: two launches on one session (a goal kept across a quit).
echo "== writing"
Scripts/writing-check.sh --out "$OUT" "$APP" || { echo "tools-check: writing FAILED" >&2; fail=1; }
# Hot close after a failed session save: needs session saving on.
echo "== closefail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-closefail" CEDRIC_CHECK=closefail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/closefail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/closefail.txt" || { echo "tools-check: closefail FAILED" >&2; fail=1; }
# Quit while the session can't be written: likewise.
echo "== reopenfail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-reopenfail" CEDRIC_CHECK=reopenfail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/reopenfail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/reopenfail.txt" || { echo "tools-check: reopenfail FAILED" >&2; fail=1; }

echo "== closedmemory"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-closedmemory" CEDRIC_CHECK=closedmemory perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/closedmemory.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/closedmemory.txt" || { echo "tools-check: closedmemory FAILED" >&2; fail=1; }

echo "== quitsyncfail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-quitsyncfail" CEDRIC_CHECK=quitsyncfail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/quitsyncfail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/quitsyncfail.txt" || { echo "tools-check: quitsyncfail FAILED" >&2; fail=1; }

echo "== backupfail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-backupfail" CEDRIC_SESSION_RETRY_DELAY=2 CEDRIC_CHECK=backupfail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/backupfail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/backupfail.txt" || { echo "tools-check: backupfail FAILED" >&2; fail=1; }

echo "== quitfail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-quitfail" CEDRIC_CHECK=quitfail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/quitfail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/quitfail.txt" || { echo "tools-check: quitfail FAILED" >&2; fail=1; }
# Quit when only the journal write fails (the session file itself is fine).
echo "== quitjournalfail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-quitjournalfail" CEDRIC_CHECK=quitjournalfail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/quitjournalfail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/quitjournalfail.txt" || { echo "tools-check: quitjournalfail FAILED" >&2; fail=1; }
# Save As whose flush to the disk fails: the tab stays unsaved, its buffer kept.
echo "== saveasflushfail"
if ! env -u CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR="$W/session-saveasflushfail" CEDRIC_CHECK=saveasflushfail perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
    | grep -E "^check:" | tee "$OUT/saveasflushfail.txt"; then fail=1; fi
grep -q "check: done .* 0 failed" "$OUT/saveasflushfail.txt" || { echo "tools-check: saveasflushfail FAILED" >&2; fail=1; }
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

#!/bin/bash
# The daily-use pass (docs/daily-use.md): realistic flows driven in
# process (CEDRIC_CHECK=dailyuse: outside open, 20 sidebar clicks, preview,
# Open Recent, folder switching, every Settings pane), a self-test of the
# known-bug markers, and the speed budgets (cold launch, sidebar clicks,
# preview toggle) checked against Scripts/daily-use-budgets.json.
#
#   Scripts/daily-use.sh [--no-build] [--runs N] [--cold N] [--out DIR] [--write-budgets] [--flows-only] [APP]
#
#   --no-build        use APP as it is (default: build a check build first
#                     with Scripts/bundle-app.sh, never --release)
#   --runs N          perf launches (default 5); a metric's value is the
#                     median of the launches' medians
#   --cold N          cold launches timed (default 7, after one warm-up)
#   --out DIR         default ~/Orchestrator/scratch/daily-use/YYYY-MM-DD
#   --flows-only      the self-test and the flows, no timings
#   --write-budgets   measure only (no flows, no verdicts) and write the
#                     baselines to Scripts/daily-use-budgets.json
#   APP               default dist/Owlink.app
#
# Writes summary.md (passes, known bugs, metrics against budgets, SKIPs,
# every FAIL line, the runtime), the raw logs and the screenshots to DIR.
# Exit 1 on any FAIL, else 0 (a known bug is a pass with a note; a SKIP is
# not a failure). Not part of CI, test.sh or verify.sh.
#
# Isolation: every launch gets temp CEDRIC_SESSION_DIR and
# CEDRIC_REPLACE_UNDO_DIR (check-env.sh), no session restore or save. The
# app runs as a COPY of the check build with its own bundle id
# (net.mindtricks.cedric.dailyuse, re-signed ad hoc), so its defaults and
# its recent-documents list are its own; both are removed at the end.
# The script checks that net.mindtricks.cedric's defaults and the mtimes
# in ~/Library/Application Support/Cedric did not change during the run
# (a change there may be the user's own Owlink, which is reported).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NO_BUILD=0
RUNS=5
COLD=7
OUT=
WRITE=0
FLOWS_ONLY=0
APP="dist/Owlink.app"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=1 ;;
        --runs) RUNS=$2; shift ;;
        --cold) COLD=$2; shift ;;
        --out) OUT=$2; shift ;;
        --write-budgets) WRITE=1 ;;
        --flows-only) FLOWS_ONLY=1 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        -*) echo "daily-use.sh: unknown option $1" >&2; exit 2 ;;
        *) APP=${1%/} ;;
    esac
    shift
done
T_START=$(date +%s)
OUT=${OUT:-$HOME/Orchestrator/scratch/daily-use/$(date +%Y-%m-%d)}
mkdir -p "$OUT/shots"
OUT=$(cd "$OUT" && pwd)
BUDGETS="$ROOT/Scripts/daily-use-budgets.json"
DOMAIN=net.mindtricks.cedric.dailyuse
# Cedric AI settings (AIStore) go to their own scratch suite: the flows
# switch "Where the AI runs" to measure the Settings pane per engine.
AISUITE=net.mindtricks.cedric.dailyuse.ai
RECENTS="$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
log() { echo "daily-use: $*"; }
load() { sysctl -n vm.loadavg | awk '{print $2}'; }
CORES=$(sysctl -n hw.ncpu)

# Disk first, then no other build running (one build at a time on this Mac).
if [ -x "$HOME/Orchestrator/t3-m4/disk-check.sh" ]; then "$HOME/Orchestrator/t3-m4/disk-check.sh"; fi
wait_builds() {
    local p busy
    while true; do
        busy=
        for p in swift-build swift-test xcodebuild swift-frontend; do pgrep -x "$p" >/dev/null && busy=$p && break; done
        [ -z "$busy" ] && return 0
        log "waiting: $busy is running"
        sleep 20
    done
}
if [ $NO_BUILD = 0 ]; then
    wait_builds
    Scripts/bundle-app.sh
fi
[ -x "$APP/Contents/MacOS/Cedric" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
. Scripts/check-env.sh
cedric_require_check_build "$APP"
W=$(mktemp -d)
cleanup() {
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    defaults delete "$AISUITE" >/dev/null 2>&1 || true
    rm -f "$RECENTS/$DOMAIN".sfl* 2>/dev/null || true
    rm -rf "$HOME/Library/Saved Application State/$DOMAIN.savedState" "$HOME/Library/Caches/$DOMAIN" \
        "$HOME/Library/WebKit/$DOMAIN" "$HOME/Library/HTTPStorages/$DOMAIN" "$HOME/Library/HTTPStorages/$DOMAIN.binarycookies" 2>/dev/null || true
    [ -d "$W/Owlink-dailyuse.app" ] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$W/Owlink-dailyuse.app" >/dev/null 2>&1 || true
    rm -rf "$W"
}
trap cleanup EXIT
cedric_isolate "$W"
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_AI_DEFAULTS=$AISUITE CEDRIC_MODELS_DIR="$W/models"
mkdir -p "$W/models"

# The copy with its own bundle id; the check build itself if that fails.
RUNAPP="$W/Owlink-dailyuse.app"
ISOLATION="copy of $APP with bundle id $DOMAIN (own defaults and recent documents)"
if ditto "$APP" "$RUNAPP" && plutil -replace CFBundleIdentifier -string "$DOMAIN" "$RUNAPP/Contents/Info.plist" \
        && codesign --force --deep --sign - "$RUNAPP" >/dev/null 2>&1 && [ -z "$(cedric_check_build_problem "$RUNAPP")" ]; then
    log "running $ISOLATION"
else
    rm -rf "$RUNAPP"
    RUNAPP=$APP
    ISOLATION="FALLBACK: $APP itself (bundle id net.mindtricks.cedric; the Open Recent flow SKIPs, it would touch the shared list)"
    log "$ISOLATION"
fi
cedric_require_check_build "$RUNAPP"
BIN="$RUNAPP/Contents/MacOS/Cedric"

# What must not change: the real domain's defaults and Owlink's support folder.
SUPPORT="$HOME/Library/Application Support/Cedric"
defaults export net.mindtricks.cedric "$W/defaults-before.plist" 2>/dev/null || : > "$W/defaults-before.plist"
stat -f '%m' "$SUPPORT" > "$W/support-before.txt" 2>/dev/null || echo none > "$W/support-before.txt"
touch "$W/marker"
own_running() { pgrep -x Cedric >/dev/null && echo yes || echo no; }
OWN_BEFORE=$(own_running)

run_check() { # NAME TIMEOUT env...
    local name=$1 timeout=$2; shift 2
    env "$@" CEDRIC_SESSION_DIR="$W/session-$name" perl -e "alarm $timeout; exec @ARGV" "$BIN" -ApplePersistenceIgnoreState YES \
        > "$OUT/$name.log" 2> "$OUT/$name.stderr.log" || true
    grep -q "^check: done" "$OUT/$name.log" || echo "check: FAIL $name: the launch ended without its summary (crash, hang or timeout after $timeout s)" >> "$OUT/$name.log"
}

: > "$OUT/results.txt"
if [ $WRITE = 0 ]; then
    log "self-test of the known-bug markers"
    run_check selftest 60 CEDRIC_CHECK=dailyuseselftest CEDRIC_CHECK_OUT="$OUT/shots"
    grep "^check: FAIL" "$OUT/selftest.log" || true
    log "flows"
    T_FLOWS=$(date +%s)
    run_check flows 600 CEDRIC_CHECK=dailyuse CEDRIC_CHECK_OUT="$OUT/shots"
    T_FLOWS=$(( $(date +%s) - T_FLOWS ))
    grep -E "^check: (FAIL|KNOWN-BUG|SKIP|done)" "$OUT/flows.log" || true
fi

if [ $FLOWS_ONLY = 0 ]; then
    log "cold launches: 1 warm-up + $COLD"
    : > "$OUT/cold.log"
    for i in $(seq 0 "$COLD"); do
        l0=$(load)
        v=$(env CEDRIC_SESSION_DIR="$W/cold-session" CEDRIC_LAUNCH_METRICS=1 CEDRIC_QUIT_AFTER_LAUNCH=1 perl -e 'alarm 60; exec @ARGV' \
            "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null | sed -n 's/^metric launch_ms=//p' | head -1) || true
        l1=$(load)
        echo "launch $i launch_ms=${v:-none} load_start=$l0 load_end=$l1" >> "$OUT/cold.log"
        if [ "$i" -gt 0 ] && [ -n "$v" ]; then echo "cold value=$v" >> "$OUT/results.txt"; fi
        echo "cold load_start=$l0 load_end=$l1 cores=$CORES" >> "$OUT/results.txt"
        sleep 1
    done
    cat "$OUT/cold.log"

    log "perf: $RUNS launches"
    : > "$W/notes.txt"
    for i in $(seq 1 "$RUNS"); do
        l0=$(load)
        run_check "perf-$i" 600 CEDRIC_CHECK=dailyuseperf CEDRIC_CHECK_OUT="$OUT/shots"
        l1=$(load)
        sed -En "s/^perf: (metric=.*|load_start=.*|skipped=.*)/run=$i \1/p" "$OUT/perf-$i.log" >> "$OUT/results.txt"
        echo "perf run $i: load (1 min) before $l0, after $l1, $CORES cores; $(grep '^perf: metric=' "$OUT/perf-$i.log" | sed 's/^perf: //' | tr '\n' ' ')" | tee -a "$W/notes.txt"
        sleep 2
    done
    grep -h "^check: FAIL" "$OUT"/perf-*.log || true

    if [ $WRITE = 1 ]; then
        echo "measured by Scripts/daily-use.sh --write-budgets --runs $RUNS --cold $COLD on $(hostname -s); baselines are medians of per-run medians (cold: of $COLD launches)" >> "$W/notes.txt"
        while read -r l; do echo "cold $l" >> "$W/notes.txt"; done < "$OUT/cold.log"
        run_check budget 60 CEDRIC_CHECK=dailyusebudget CEDRIC_DAILYUSE_RESULTS="$OUT/results.txt" CEDRIC_DAILYUSE_BUDGETS="$BUDGETS" \
            CEDRIC_DAILYUSE_WRITE=1 CEDRIC_DAILYUSE_HOST="$(hostname -s)" CEDRIC_DAILYUSE_NOTES="$W/notes.txt"
        grep "^check:" "$OUT/budget.log"
        cat "$BUDGETS"
    else
        run_check budget 60 CEDRIC_CHECK=dailyusebudget CEDRIC_DAILYUSE_RESULTS="$OUT/results.txt" CEDRIC_DAILYUSE_BUDGETS="$BUDGETS"
    fi
fi

# Isolation: nothing of the real domain or support folder changed.
ISO_FAIL=
defaults export net.mindtricks.cedric "$W/defaults-after.plist" 2>/dev/null || : > "$W/defaults-after.plist"
stat -f '%m' "$SUPPORT" > "$W/support-after.txt" 2>/dev/null || echo none > "$W/support-after.txt"
changed=$(find "$SUPPORT" -maxdepth 2 -newer "$W/marker" 2>/dev/null | sed "s|^$HOME|~|" | head -5 || true)
own_note=
[ "$OWN_BEFORE" = yes ] || [ "$(own_running)" = yes ] && own_note=" (a process named Cedric other than the pass ran: the user's own Owlink may have made the change)"
if ! cmp -s "$W/defaults-before.plist" "$W/defaults-after.plist"; then ISO_FAIL="net.mindtricks.cedric defaults changed during the run$own_note"; fi
if ! cmp -s "$W/support-before.txt" "$W/support-after.txt" || [ -n "$changed" ]; then
    ISO_FAIL="${ISO_FAIL:+$ISO_FAIL; }~/Library/Application Support/Cedric changed during the run$own_note: ${changed:-the folder mtime}"
fi
[ -n "$ISO_FAIL" ] && echo "check: FAIL isolation: $ISO_FAIL" > "$OUT/isolation.log" || echo "check: PASS isolation: net.mindtricks.cedric defaults and ~/Library/Application Support/Cedric unchanged" > "$OUT/isolation.log"

RUNTIME=$(( $(date +%s) - T_START ))
# The summary.
{
    echo "# Owlink daily-use pass, $(date '+%Y-%m-%d %H:%M %Z') on $(hostname -s)"
    echo
    echo "- Commit: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))$(git diff --quiet HEAD -- || echo ', with local changes')"
    echo "- App: $ISOLATION"
    echo "- Total runtime: ${RUNTIME} s$( [ $WRITE = 0 ] && echo " (flows ${T_FLOWS} s)")"
    echo "- Load now: $(sysctl -n vm.loadavg) on $CORES cores"
    echo
    if [ $WRITE = 0 ]; then
        echo "## Flows"
        echo
        grep -h "^check: done" "$OUT/selftest.log" "$OUT/flows.log" | sed 's/^check: /- /'
        echo "- Passing assertions: $(grep -c '^check: PASS' "$OUT/flows.log" || true)"
        echo
        echo "## Known bugs (expected failures, still open)"
        echo
        grep -h "^check: KNOWN-BUG" "$OUT/flows.log" | sed 's/^check: KNOWN-BUG /- /' || echo "- none"
        echo
    fi
    echo "## Speed"
    echo
    echo '```'
    grep -hE "^metric |^check: (PASS|FAIL|SKIP)" "$OUT/budget.log" 2>/dev/null || echo "(not measured: --flows-only)"
    echo '```'
    echo
    echo "## SKIPs"
    echo
    grep -h "^check: SKIP" "$OUT"/*.log | sed 's/^check: SKIP /- /' || echo "- none"
    echo
    echo "## Findings (every FAIL)"
    echo
    grep -H "^check: FAIL" "$OUT"/*.log | sed "s|^$OUT/||; s/^/- /" || echo "- none"
    echo
    echo "## Files"
    echo
    echo "Logs: $OUT/*.log. Screenshots: $OUT/shots ($(ls "$OUT/shots" | grep -c '\.png$' || true) PNGs)."
} > "$OUT/summary.md"
cat "$OUT/summary.md"
log "runtime ${RUNTIME} s; summary in $OUT/summary.md"
if grep -q "^check: FAIL" "$OUT"/*.log; then exit 1; fi
exit 0

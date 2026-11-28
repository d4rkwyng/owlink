#!/bin/bash
# The daily-use pass (docs/daily-use.md): realistic flows driven in
# process (CEDRIC_CHECK=dailyuse: outside open, 20 sidebar clicks, preview,
# Open Recent, folder switching, every Settings pane), a self-test of the
# known-bug markers, and the speed budgets (cold launch, sidebar clicks,
# preview toggle) checked against Scripts/daily-use-budgets.json.
#
#   Scripts/daily-use.sh [--no-build] [--runs N] [--cold N] [--out DIR] [--write-budgets [--metrics LIST]] [--flows-only] [APP]
#
#   --no-build        use APP as it is (default: build a check build first
#                     with Scripts/bundle-app.sh, never --release)
#   --runs N          perf launches (default 5); a metric's value is the
#                     median of the launches' medians
#   --cold N          cold launches timed (default 7, after one warm-up)
#   --out DIR         default ~/Orchestrator/scratch/daily-use/YYYY-MM-DD
#   --flows-only      the self-test and the flows, no timings
#   --write-budgets   measure only (no flows, no verdicts) and write the
#                     baselines to Scripts/daily-use-budgets.json. Only a
#                     complete collection replaces the file: every launch
#                     asked for, none failed, skipped or under heavy load.
#                     Not with --flows-only.
#   --metrics LIST    with --write-budgets: re-measure these metrics only
#                     (comma separated), keeping the others' entries
#   APP               default dist/Owlink.app
#
# Writes summary.md (passes, known bugs, metrics against budgets, SKIPs,
# every FAIL line, the runtime), the raw logs and the screenshots to DIR.
# The summary and the exit status are about this invocation's launches
# only: logs an earlier run left in DIR are not read.
# Exit 1 on any FAIL, else 0 (a known bug is a pass with a note; a SKIP is
# not a failure). Not part of CI, test.sh or verify.sh.
#
# Isolation: every launch gets temp CEDRIC_SESSION_DIR and
# CEDRIC_REPLACE_UNDO_DIR (check-env.sh), no session restore or save. The
# app runs as a COPY of the check build with its own bundle id
# (net.mindtricks.cedric.dailyuse, re-signed ad hoc), so its defaults and
# its recent-documents list are its own; both are removed at the end.
# If that copy cannot be made, signed and read back, the script exits 1
# and launches nothing: the check build itself is never run. The script
# checks that every launch reported the copy, the scratch folders and the
# scratch suite; that none of the pass's fixture files (cedric-check-
# dailyuse*) came into net.mindtricks.cedric's recent-documents list (a
# change there without them is another check lane or the user's own
# Owlink: a note); and that net.mindtricks.cedric's defaults did not
# change (a change while another process named Cedric was seen cannot be
# pinned on the pass: a SKIP). It does not look inside
# ~/Library/Application Support/Cedric.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NO_BUILD=0
RUNS=5
COLD=7
OUT=
WRITE=0
FLOWS_ONLY=0
METRICS=
APP="dist/Owlink.app"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=1 ;;
        --runs) RUNS=$2; shift ;;
        --cold) COLD=$2; shift ;;
        --out) OUT=$2; shift ;;
        --write-budgets) WRITE=1 ;;
        --flows-only) FLOWS_ONLY=1 ;;
        --metrics) METRICS=$2; shift ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        -*) echo "daily-use.sh: unknown option $1" >&2; exit 2 ;;
        *) APP=${1%/} ;;
    esac
    shift
done
if [ $WRITE = 1 ] && [ $FLOWS_ONLY = 1 ]; then
    echo "daily-use.sh: --write-budgets and --flows-only do not go together (one measures only, the other does not measure)" >&2; exit 2
fi
if [ -n "$METRICS" ] && [ $WRITE = 0 ]; then echo "daily-use.sh: --metrics is for --write-budgets" >&2; exit 2; fi
ALL_METRICS="cold_launch_ms preview_toggle_ms sidebar_log_ms sidebar_md_ms sidebar_switch_ms"
for m in ${METRICS//,/ }; do
    case " $ALL_METRICS " in *" $m "*) ;; *) echo "daily-use.sh: --metrics: $m is not one of: $ALL_METRICS" >&2; exit 2 ;; esac
done
# Cold launches and perf launches are run only for the metrics asked for.
NEED_COLD=1; NEED_PERF=1
if [ -n "$METRICS" ]; then
    case ",$METRICS," in *,cold_launch_ms,*) ;; *) NEED_COLD=0 ;; esac
    [ "$METRICS" = cold_launch_ms ] && NEED_PERF=0
fi
T_START=$(date +%s)
OUT=${OUT:-$HOME/Orchestrator/scratch/daily-use/$(date +%Y-%m-%d)}
mkdir -p "$OUT/shots"
OUT=$(cd "$OUT" && pwd)
BUDGETS="$ROOT/Scripts/daily-use-budgets.json"
DOMAIN=net.mindtricks.cedric.dailyuse
# Cedric AI settings (AIStore) go to their own scratch suite: the flows
# switch "Where the AI runs" to measure the Settings pane per engine.
AISUITE=net.mindtricks.cedric.dailyuse.ai
REAL=net.mindtricks.cedric
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
# The physical path (no /var → /private/var link): launches report it back.
W=$(cd "$(mktemp -d)" && pwd -P)
cleanup() {
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    defaults delete "$AISUITE" >/dev/null 2>&1 || true
    # defaults delete leaves an empty plist behind: remove the files too.
    rm -f "$HOME/Library/Preferences/$DOMAIN.plist" "$HOME/Library/Preferences/$AISUITE.plist"
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

# The copy with its own bundle id. No copy, no run: the check build
# itself has the user's bundle id, so its opens would go to the user's
# recent documents and its settings to the user's defaults.
RUNAPP="$W/Owlink-dailyuse.app"
ISOLATION="copy of $APP with bundle id $DOMAIN (own defaults and recent documents)"
prepare_copy() {
    ditto "$APP" "$RUNAPP" || { echo "ditto failed"; return 1; }
    plutil -replace CFBundleIdentifier -string "$DOMAIN" "$RUNAPP/Contents/Info.plist" || { echo "plutil could not set the bundle id"; return 1; }
    codesign --force --deep --sign - "$RUNAPP" >/dev/null 2>&1 || { echo "codesign (ad hoc) failed"; return 1; }
    codesign --verify --deep "$RUNAPP" >/dev/null 2>&1 || { echo "the copy's signature does not verify"; return 1; }
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$RUNAPP/Contents/Info.plist" 2>/dev/null)" = "$DOMAIN" ] || { echo "the copy's bundle id does not read back as $DOMAIN"; return 1; }
    local why
    why=$(cedric_check_build_problem "$RUNAPP") || { echo "$why"; return 1; }
    [ -x "$RUNAPP/Contents/MacOS/Cedric" ] || { echo "the copy has no executable"; return 1; }
}
if ! why=$(prepare_copy); then
    echo "daily-use.sh: cannot prepare the isolated copy of $APP (${why:-unknown}). Nothing was launched: $APP itself has the bundle id $REAL and would write the user's recent documents and defaults." >&2
    exit 1
fi
log "running $ISOLATION"
cedric_require_check_build "$RUNAPP"
BIN="$RUNAPP/Contents/MacOS/Cedric"

# What must not change: the real domain's defaults and its recent
# documents. (Nothing here looks inside ~/Library/Application Support/Cedric.)
defaults export "$REAL" "$W/defaults-before.plist" 2>/dev/null || : > "$W/defaults-before.plist"
recents_sum() { { cat "$RECENTS/$REAL".sfl* 2>/dev/null || true; } | shasum | awk '{print $1}'; }
# The pass's fixture folders (cedric-check-dailyuse…-PID in the temp
# folder) named in the real list: a file of the pass that went there.
ours_in_recents() { { cat "$RECENTS/$REAL".sfl* 2>/dev/null || true; } | strings | grep -oE 'cedric-check-dailyuse[a-z]*-[0-9]+' | sort -u || true; }
RECENTS_BEFORE=$(recents_sum)
ours_in_recents > "$W/ours-before.txt"
touch "$W/marker"
# Another process named Cedric (another check lane, the user's own Owlink):
# looked for whenever the pass itself has no launch running.
OTHER=no
note_other() { if pgrep -x Cedric >/dev/null; then OTHER=yes; fi; }
note_other

# This invocation's logs: the summary and the exit status read these only.
LOGS=()
run_check() { # NAME TIMEOUT env...
    local name=$1 timeout=$2; shift 2
    LOGS+=("$OUT/$name.log")
    note_other
    env "$@" CEDRIC_SESSION_DIR="$W/session-$name" perl -e "alarm $timeout; exec @ARGV" "$BIN" -ApplePersistenceIgnoreState YES \
        > "$OUT/$name.log" 2> "$OUT/$name.stderr.log" || true
    grep -q "^check: done" "$OUT/$name.log" || echo "check: FAIL $name: the launch ended without its summary (crash, hang or timeout after $timeout s)" >> "$OUT/$name.log"
    # The launch must say it ran as the copy, with the scratch folders and suite.
    local want="check: note: isolation: bundle=$DOMAIN app=$RUNAPP session=$W/session-$name replace-undo=$CEDRIC_REPLACE_UNDO_DIR models=$CEDRIC_MODELS_DIR ai-defaults=$AISUITE"
    if grep -qxF "$want" "$OUT/$name.log"; then ISO_OK=$((ISO_OK + 1)); else ISO_BAD="${ISO_BAD:+$ISO_BAD, }$name"; fi
}
ISO_OK=0
ISO_BAD=

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

PERF_FAILED=0
if [ $FLOWS_ONLY = 0 ]; then
  if [ $NEED_COLD = 1 ]; then
    log "cold launches: 1 warm-up + $COLD"
    : > "$OUT/cold.log"
    for i in $(seq 0 "$COLD"); do
        l0=$(load)
        v=$(env CEDRIC_SESSION_DIR="$W/cold-session" CEDRIC_LAUNCH_METRICS=1 CEDRIC_QUIT_AFTER_LAUNCH=1 perl -e 'alarm 60; exec @ARGV' \
            "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null | sed -n 's/^metric launch_ms=//p' | head -1) || true
        l1=$(load)
        echo "launch $i launch_ms=${v:-none} load_start=$l0 load_end=$l1" >> "$OUT/cold.log"
        # One line per launch: its value with its own load (the warm-up has no value).
        if [ "$i" -gt 0 ] && [ -n "$v" ]; then
            echo "cold=$i value=$v load_start=$l0 load_end=$l1 cores=$CORES" >> "$OUT/results.txt"
        else
            echo "cold=$i load_start=$l0 load_end=$l1 cores=$CORES" >> "$OUT/results.txt"
        fi
        sleep 1
    done
    cat "$OUT/cold.log"
  fi

  : > "$W/notes.txt"
  if [ $NEED_PERF = 1 ]; then
    log "perf: $RUNS launches"
    for i in $(seq 1 "$RUNS"); do
        l0=$(load)
        run_check "perf-$i" 600 CEDRIC_CHECK=dailyuseperf CEDRIC_CHECK_OUT="$OUT/shots"
        l1=$(load)
        sed -En "s/^perf: (metric=.*|load_start=.*|skipped=.*)/run=$i \1/p" "$OUT/perf-$i.log" >> "$OUT/results.txt"
        if grep -q "^check: FAIL" "$OUT/perf-$i.log"; then echo "run=$i failed=1" >> "$OUT/results.txt"; PERF_FAILED=$((PERF_FAILED + 1)); fi
        echo "perf run $i: load (1 min) before $l0, after $l1, $CORES cores; $(grep '^perf: metric=' "$OUT/perf-$i.log" | sed 's/^perf: //' | tr '\n' ' ')" | tee -a "$W/notes.txt"
        sleep 2
    done
    for i in $(seq 1 "$RUNS"); do grep -h "^check: FAIL" "$OUT/perf-$i.log" || true; done
    [ $PERF_FAILED = 0 ] || log "$PERF_FAILED of $RUNS perf launches failed"
  fi

    if [ $WRITE = 1 ]; then
        echo "measured by Scripts/daily-use.sh --write-budgets${METRICS:+ --metrics $METRICS} --runs $RUNS --cold $COLD on $(hostname -s); baselines are medians of per-run medians (cold: of $COLD launches)" >> "$W/notes.txt"
        if [ $NEED_COLD = 1 ]; then while read -r l; do echo "cold $l" >> "$W/notes.txt"; done < "$OUT/cold.log"; fi
        # The writer (DailyUseBudget.writeBaselines) replaces the file only
        # with a complete collection; a failed perf launch is in results.txt.
        SUM_BEFORE=$(shasum "$BUDGETS" 2>/dev/null | awk '{print $1}')
        run_check budget 60 CEDRIC_CHECK=dailyusebudget CEDRIC_DAILYUSE_RESULTS="$OUT/results.txt" CEDRIC_DAILYUSE_BUDGETS="$BUDGETS" \
            CEDRIC_DAILYUSE_WRITE=1 CEDRIC_DAILYUSE_HOST="$(hostname -s)" CEDRIC_DAILYUSE_NOTES="$W/notes.txt" \
            CEDRIC_DAILYUSE_RUNS="$RUNS" CEDRIC_DAILYUSE_COLD="$COLD" CEDRIC_DAILYUSE_METRICS="${METRICS:-${ALL_METRICS// /,}}"
        grep "^check:" "$OUT/budget.log"
        if [ "$SUM_BEFORE" = "$(shasum "$BUDGETS" 2>/dev/null | awk '{print $1}')" ]; then
            log "$BUDGETS is unchanged"
        else
            cat "$BUDGETS"
        fi
    else
        run_check budget 60 CEDRIC_CHECK=dailyusebudget CEDRIC_DAILYUSE_RESULTS="$OUT/results.txt" CEDRIC_DAILYUSE_BUDGETS="$BUDGETS"
    fi
fi

# Isolation: every launch was the copy with the scratch folders and
# suite; none of the pass's files are in the real recent documents; the
# real domain's defaults did not change.
ISO_FAIL=
ISO_NOTE=
ISO_SKIP=
note_other
defaults export "$REAL" "$W/defaults-after.plist" 2>/dev/null || : > "$W/defaults-after.plist"
if [ -n "$ISO_BAD" ]; then ISO_FAIL="these launches did not report the copy ($DOMAIN at $RUNAPP) with the scratch folders and suite: $ISO_BAD"; fi
ours_in_recents > "$W/ours-after.txt"
LEAKED=$(comm -13 "$W/ours-before.txt" "$W/ours-after.txt" | tr '\n' ' ')
if [ -n "$LEAKED" ]; then
    ISO_FAIL="${ISO_FAIL:+$ISO_FAIL; }files of the pass came into $REAL's recent-documents list: $LEAKED"
elif [ "$RECENTS_BEFORE" != "$(recents_sum)" ]; then
    ISO_NOTE="$REAL's recent-documents list changed during the run, with none of the pass's files in it (another check lane or the user's own Owlink)"
fi
if ! cmp -s "$W/defaults-before.plist" "$W/defaults-after.plist"; then
    if [ $OTHER = yes ]; then
        ISO_SKIP="$REAL's defaults changed during the run while another process named Cedric ran (another check lane or the user's own Owlink): it cannot be pinned on the pass"
    else
        ISO_FAIL="${ISO_FAIL:+$ISO_FAIL; }$REAL's defaults changed during the run, and no other process named Cedric was seen"
    fi
fi
LOGS+=("$OUT/isolation.log")
if [ -n "$ISO_FAIL" ]; then
    echo "check: FAIL isolation: $ISO_FAIL" > "$OUT/isolation.log"
else
    echo "check: PASS isolation: $ISO_OK launches ran as the copy ($DOMAIN) with scratch session, undo and models folders and the scratch AI suite; none of the pass's files are in $REAL's recent documents${ISO_SKIP:+ (defaults: see the SKIP)}${ISO_SKIP:-; its defaults are unchanged}" > "$OUT/isolation.log"
fi
[ -z "$ISO_SKIP" ] || echo "check: SKIP isolation (the real defaults): $ISO_SKIP" >> "$OUT/isolation.log"
[ -z "$ISO_NOTE" ] || echo "check: note: $ISO_NOTE" >> "$OUT/isolation.log"

RUNTIME=$(( $(date +%s) - T_START ))
# The summary.
{
    echo "# Owlink daily-use pass, $(date '+%Y-%m-%d %H:%M %Z') on $(hostname -s)"
    echo
    echo "- Commit: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))$(git diff --quiet HEAD -- || echo ', with local changes')"
    echo "- App: $ISOLATION"
    echo "- Total runtime: ${RUNTIME} s$( [ $WRITE = 0 ] && echo " (flows ${T_FLOWS} s)" || true)"
    echo "- Logs of this invocation: $(for l in "${LOGS[@]}"; do basename "$l"; done | tr '\n' ' ')"
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
    if [ $FLOWS_ONLY = 1 ]; then echo "(not measured: --flows-only)"; else grep -hE "^metric |^check: (PASS|FAIL|SKIP)" "$OUT/budget.log" || echo "(no verdicts)"; fi
    echo '```'
    echo
    echo "## SKIPs"
    echo
    grep -h "^check: SKIP" "${LOGS[@]}" | sed 's/^check: SKIP /- /' | grep . || echo "- none"
    echo
    echo "## Findings (every FAIL)"
    echo
    grep -H "^check: FAIL" "${LOGS[@]}" | sed "s|^$OUT/||; s/^/- /" | grep . || echo "- none"
    echo
    echo "## Files"
    echo
    echo "Logs: $OUT/*.log (this invocation's are listed above). Screenshots: $OUT/shots ($(find "$OUT/shots" -name '*.png' -newer "$W/marker" | wc -l | tr -d ' ') PNGs from this invocation)."
} > "$OUT/summary.md"
cat "$OUT/summary.md"
log "runtime ${RUNTIME} s; summary in $OUT/summary.md"
if grep -q "^check: FAIL" "${LOGS[@]}"; then exit 1; fi
exit 0

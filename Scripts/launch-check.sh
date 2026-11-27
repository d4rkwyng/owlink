#!/bin/bash
# Real-launch smoke test, after Tankard's: launches "Owlink.app" the way a
# user does (no CEDRIC_* switches, the real session restored), checks it is
# still running after a while and left no new crash report, then quits it
# with a Quit Apple event. Run it before every release. Needs a logged-in
# GUI session (works with the screen locked).
#
#   Scripts/launch-check.sh [--release] [--no-build] [--seconds N] [--runs N] [PATH.app]
#
#   PATH.app      an existing app to check (implies --no-build)
#   --release     the app is to ship (Scripts/release.sh passes it): fail
#                 unless it reports its dev switches compiled out ("dev
#                 hooks: off"), so a check build can't ship by accident;
#                 when building, builds with bundle-app.sh --release
#   --no-build    use the existing "dist/Owlink.app"
#   --seconds N   how long it must stay up (default: 10)
#   --runs N      launch it N times in a row (default: 3)
#
# It restores and re-saves the real session, as every launch does; it
# never edits or saves a document. The real launches still get
# CEDRIC_REPLACE_UNDO_DIR (a temp folder): a check build would otherwise
# prune the real Replace in Files undo copies at launch; a release build
# ignores it and keeps its normal retention (Scripts/check-env.sh).
#
# isolation-lint: release-gate (launches release builds as shipped)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Owlink.app"
SECONDS_UP=10
RUNS=3
BUILD=1
RELEASE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --release) RELEASE=1 ;;
        --seconds) SECONDS_UP=$2; shift ;;
        --runs) RUNS=$2; shift ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *.app|*.app/) APP=${1%/}; BUILD=0 ;;
        *) echo "launch-check.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

if [ $BUILD = 1 ]; then
    if [ $RELEASE = 1 ]; then Scripts/bundle-app.sh --release --out "$(dirname "$APP")"; else Scripts/bundle-app.sh --out "$(dirname "$APP")"; fi
fi
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "launch-check.sh: no app at $APP" >&2; exit 1; }

REPORTS=~/Library/Logs/DiagnosticReports
crash_reports() { ls "$REPORTS" 2>/dev/null | grep -E '^Cedric[-_.]' || true; }
reports_for() {
    local pid=$1 f
    for f in $(comm -13 <(echo "$2") <(crash_reports)); do
        grep -qE "\"pid\" *: *$pid,|^Process: .*\[$pid\]" "$REPORTS/$f" 2>/dev/null && echo "$REPORTS/$f"
    done
    return 0
}

ENV_CLEAN=(env)
for v in $(env | sed -n 's/^\(CEDRIC_[A-Z_]*\)=.*/\1/p'); do ENV_CLEAN+=(-u "$v"); done

BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/Cedric
if pgrep -f "^$BIN_ABS" >/dev/null; then
    echo "launch-check.sh: $APP is already running; quit it first" >&2
    exit 1
fi

LW=$(mktemp -d)
trap 'rm -rf "$LW"' EXIT
failed=0
# The built-in engine's llama.framework isn't linked (dlopen on first use,
# CLlamaLoader), so a missing or broken copy no longer stops the launch:
# check that it loads from the bundle. The same run says whether the dev
# switches are compiled in ("dev hooks: on" = a check build).
out=$("${ENV_CLEAN[@]}" CEDRIC_LLAMA_CHECK=1 CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_SESSION_DIR="$LW/session" CEDRIC_REPLACE_UNDO_DIR="$LW/replace-undo" \
        "$BIN_ABS" -ApplePersistenceIgnoreState YES 2>/dev/null) || true
if grep -qx "llama: ok" <<<"$out"; then
    echo "launch-check: llama.framework loads from the bundle"
else
    echo "launch-check: FAILED llama.framework did not load: $out" >&2
    failed=1
fi
hooks=$(sed -n 's/^dev hooks: //p' <<<"$out")
if [ $RELEASE = 1 ]; then
    if [ "$hooks" = off ]; then
        echo "launch-check: release build (dev hooks: off)"
    else
        echo "launch-check: FAILED --release: the app reports dev hooks: ${hooks:-nothing}; a check build must not ship (bundle-app.sh --release)" >&2
        failed=1
    fi
else
    echo "launch-check: dev hooks: ${hooks:-not reported}"
fi
for run in $(seq 1 "$RUNS"); do
    before=$(crash_reports)
    # isolation-lint: real-launch the user's real session, as a user launches it
    "${ENV_CLEAN[@]}" CEDRIC_REPLACE_UNDO_DIR="$LW/replace-undo" "$BIN_ABS" >/dev/null 2>&1 &
    pid=$!
    alive=1
    for _ in $(seq 1 "$SECONDS_UP"); do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    done
    status=running
    if [ $alive = 1 ]; then
        osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate; ''" >/dev/null 2>&1 || true
        quit=0
        for _ in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || { quit=1; break; }; sleep 1; done
        if [ $quit = 0 ]; then status="did not quit on a Quit event (a prompt?)"; kill -9 "$pid" 2>/dev/null || true; alive=0; fi
        wait "$pid" 2>/dev/null || true
    else
        wait "$pid" && status="exited 0" || status="exited $?"
    fi
    sleep 3
    new=$(reports_for "$pid" "$before" | tr '\n' ' ')
    if [ $alive = 1 ] && [ -z "$new" ]; then
        echo "launch-check: run $run/$RUNS OK (up ${SECONDS_UP}s, quit cleanly, no crash report)"
    else
        echo "launch-check: run $run/$RUNS FAILED ($status${new:+, new report: $new})" >&2
        failed=1
    fi
done
exit $failed

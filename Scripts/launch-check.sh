#!/bin/bash
# Real-launch smoke test, after Tankard's: launches "Owlink.app" with no
# CEDRIC_* switches but its own folders, checks it is still running after
# a while and left no new crash report, then quits it with a Quit Apple
# event. Needs a logged-in GUI session (works with the screen locked).
#
#   Scripts/launch-check.sh [--release] [--no-build] [--seconds N] [--runs N] [PATH.app]
#
#   PATH.app      an existing app to check (implies --no-build)
#   --release     the app is to ship (Scripts/release.sh passes it): a
#                 RELEASE GATE, see below. Fails unless the bundle has no
#                 CedricCheckBuild marker and the app reports its dev
#                 switches compiled out ("dev hooks: off"), so a check
#                 build can't ship by accident; when building, builds with
#                 bundle-app.sh --release
#   --no-build    use the existing "dist/Owlink.app"
#   --seconds N   how long it must stay up (default: 10)
#   --runs N      launch it N times in a row (default: 3)
#
# Dev mode (no --release, what a maintainer runs): the bundle must be a
# check build, decided from its Info.plist before anything runs
# (cedric_require_check_build, Scripts/check-env.sh). Every launch gets a
# temp CEDRIC_SESSION_DIR and CEDRIC_REPLACE_UNDO_DIR. The runs share one
# session folder, so run 1 starts empty and saves its session on the Quit,
# and every later run restores that session: restore and save stay under
# test, on a session of the check's own, never the real one. The real
# ~/Library/Application Support/Cedric is not read or written.
#
# --release is a release gate. A release binary ignores both folder
# overrides, so every launch rotates the real cli-token and prunes the
# real ReplaceUndo of the account it runs in (it honours CEDRIC_NO_RESTORE
# and CEDRIC_NO_SESSION_SAVE, which it gets, so Session is left alone).
# Run it only in a disposable macOS user account or VM: it refuses to
# start unless OWLINK_RELEASE_GATE=1, which only Scripts/release.sh sets,
# on its release path (cedric_require_release_gate).
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
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
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
. Scripts/check-env.sh
if [ $RELEASE = 1 ]; then
    cedric_require_release_gate
    # Static, before it runs: a marked check build must not ship.
    marker=$(plutil -extract CedricCheckBuild raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)
    [ -z "$marker" ] || { echo "launch-check: FAILED --release: $APP carries CedricCheckBuild=$marker in its Info.plist (a check build must not ship); launched nothing" >&2; exit 1; }
    # Honoured by a release build: no restore, no save of the real session.
    GATE_ENV=(CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1)
else
    cedric_require_check_build "$APP"
    GATE_ENV=()
fi

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
cedric_isolate "$LW"
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
    # One session folder for all runs: run 1 saves it, later runs restore it.
    "${ENV_CLEAN[@]}" CEDRIC_SESSION_DIR="$LW/session" CEDRIC_REPLACE_UNDO_DIR="$LW/replace-undo" ${GATE_ENV[@]+"${GATE_ENV[@]}"} \
        "$BIN_ABS" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
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
    saved=""
    if [ $RELEASE = 0 ] && [ $alive = 1 ]; then
        # The Quit saved the check's own session (restored by the next run).
        if [ -s "$LW/session/session.json" ]; then saved=", saved its temp session"
        else status="no session.json in the temp session folder after the Quit"; alive=0; fi
    fi
    if [ $alive = 1 ] && [ -z "$new" ]; then
        echo "launch-check: run $run/$RUNS OK (up ${SECONDS_UP}s, quit cleanly$saved, no crash report)"
    else
        echo "launch-check: run $run/$RUNS FAILED ($status${new:+, new report: $new})" >&2
        failed=1
    fi
done
exit $failed

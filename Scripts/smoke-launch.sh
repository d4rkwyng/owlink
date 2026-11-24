#!/bin/bash
# Clean-machine launch smoke test for the zip that ships, after First
# Light's (d4rkwyng/first-light#22, its 1.0.0/1.0.1 launch crash).
#
#   Scripts/smoke-launch.sh [--seconds N] [--allow-check-build] PATH/Owlink-X.Y.Z.zip
#
#   --seconds N           how long the app must stay up (default: 10)
#   --allow-check-build   accept a build with the dev switches compiled in
#                         (local tries only; a release must report "off")
#
# Unzips the zip (ditto, like Finder) into a fresh temp folder and checks
# that copy of Owlink.app, never the build tree's:
#   1. Layout: every file the app looks up through Bundle.main is in
#      Contents/Resources (owl art, the model list, the tool scores, the
#      model licences, the `cedric` launcher), Contents/MacOS/Cedric and
#      Contents/Frameworks/llama.framework exist, nothing sits at the .app
#      root, and no SwiftPM *.bundle is expected (Owlink has none today; if
#      one appears it must be in Contents/Resources).
#   2. Hides the build machine's fallbacks while the app runs. The app's
#      resource lookups fall back to the source tree through #filePath
#      (OwlArt, ModelCatalog, OwlToolGate: <checkout>/Resources/...), and a
#      SwiftPM Bundle.module accessor would fall back to its absolute .build
#      path. Both are compiled into the binary, so on the machine (or CI
#      runner) that built the app they exist and would mask a zip that lacks
#      its resources. The script reads the checkout roots embedded in the
#      executable (absolute …/Sources/<Target>/….swift paths), plus its own
#      checkout, and renames each root's Resources and .build to
#      "<path>.smoke-hidden", plus any other embedded absolute *.bundle path.
#      A trap renames them back on exit, failure or Ctrl-C; if one can't be
#      restored the script says what to `mv` and exits non-zero. Don't run
#      it while a build or test run is using that checkout.
#   3. CEDRIC_LLAMA_CHECK run (a release-allowed switch): must print
#      "llama: ok" (llama.framework dlopens from Contents/Frameworks) and
#      "dev hooks: off" (a release build).
#   4. A real launch (no session restored or saved, so a developer's real
#      session is untouched): must stay up N seconds, then quit within 8 s
#      of a Quit (NSRunningApplication.terminate, an Apple Event from
#      osascript under a 10 s alarm). A missed Quit fails and prints
#      osascript's exit code, stdout and stderr (the event may not have
#      been delivered: Automation/TCC).
#   5. No new crash report (.ips or .crash) anywhere under
#      ~/Library/Logs/DiagnosticReports or /Library/Logs/DiagnosticReports
#      (Retired/ included) whose name starts with Cedric, CedricApp,
#      Owlink, or any app-like bundle or Contents/MacOS executable name in
#      the zip (not a framework's: those crash under the host's name). New = a file name not in a listing taken before the first run
#      (by name, not mtime: ReportCrash touches old reports and moves some
#      into Retired/); an empty listing (a clean runner) works too. It
#      waits up to 10 s for ReportCrash after the app exits. The script
#      never moves or deletes a report. Test-only: SMOKE_REPORT_DIRS
#      (colon-separated folders), if set and non-empty, replaces those two
#      folders; the release workflow never sets it.
# Exit 0 = SMOKE PASS. Needs a logged-in GUI session (CI runners have one).
#
# Not covered: a failure after the N-second window, and resources the app
# only reads on user action (owl art when the owl first shows, licences at
# download time). Step 1 checks those files are where the app looks, and
# step 2 makes sure nothing else could answer for them. Opening a big
# file isn't covered either (a release build has no switch to open one
# with): Scripts/bigfile-check.sh opens a generated 55 MiB log in a check
# build and fails on a crash report (0.5.2's macOS 26 crash).
set -euo pipefail

SECONDS_UP=10
ALLOW_CHECK=0
ZIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_UP=$2; shift ;;
        --allow-check-build) ALLOW_CHECK=1 ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
        -*) echo "smoke-launch.sh: unknown option $1" >&2; exit 2 ;;
        *) ZIP=$1 ;;
    esac
    shift
done
[ -n "$ZIP" ] && [ -f "$ZIP" ] || { echo "usage: $0 [--seconds N] [--allow-check-build] PATH/Owlink-X.Y.Z.zip" >&2; exit 2; }
ZIP=$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")
HERE=$(cd "$(dirname "$0")/.." && pwd)

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
# Runs a command with a time limit (perl's alarm: no coreutils `timeout`
# on a stock Mac).
with_alarm() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

TMP=""
PID=""
HIDDEN=()
RESTORE_FAILED=0
restore() {
    local d stuck=()
    for d in ${HIDDEN[@]+"${HIDDEN[@]}"}; do
        if [ -e "$d.smoke-hidden" ] && [ ! -e "$d" ] && mv "$d.smoke-hidden" "$d"; then
            echo "restored $d"
        elif [ -e "$d" ] && [ ! -e "$d.smoke-hidden" ]; then
            :   # already back
        else
            stuck+=("$d"); RESTORE_FAILED=1
            echo "SMOKE ERROR: could not restore $d; fix by hand: mv '$d.smoke-hidden' '$d'" >&2
        fi
    done
    HIDDEN=(${stuck[@]+"${stuck[@]}"})
}
cleanup() {
    local rc=$?
    [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
    restore
    [ -n "$TMP" ] && rm -rf "$TMP"
    if [ $RESTORE_FAILED = 1 ]; then
        echo "SMOKE ERROR: build-machine path(s) left renamed (see above)" >&2
        exit 1
    fi
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# 0. A fresh copy of what ships.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/owlink-smoke.XXXXXX")
mkdir "$TMP/unzipped"
ditto -x -k "$ZIP" "$TMP/unzipped"
APP="$TMP/unzipped/Owlink.app"
[ -d "$APP" ] || { ls -la "$TMP/unzipped" >&2; fail "$ZIP does not unpack to Owlink.app"; }
echo "unzipped $(basename "$ZIP") to $APP"
EXE="$APP/Contents/MacOS/Cedric"
RES="$APP/Contents/Resources"

# 1. Layout.
[ -x "$EXE" ] || fail "no executable at Contents/MacOS/Cedric"
[ -d "$APP/Contents/Frameworks/llama.framework" ] || fail "no Contents/Frameworks/llama.framework"
for f in Owl/owl-idle.png Owl/owl-idle@2x.png AI/models.json AI/owl-tool-scores.json \
         AI/licenses/Apache-2.0.txt AI/licenses/Qwen-Research-License.txt cedric AppIcon.icns; do
    [ -s "$RES/$f" ] || fail "missing Contents/Resources/$f"
done
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist does not parse"
ICONS=()
while IFS= read -r i; do [ -n "$i" ] && ICONS+=("$i"); done < <(
    plutil -extract CFBundleDocumentTypes json -o - "$APP/Contents/Info.plist" \
        | grep -o '"CFBundleTypeIconFile":"[^"]*"' | sed 's/.*:"//; s/"$//' | sort -u)
for i in ${ICONS[@]+"${ICONS[@]}"}; do
    [ -s "$RES/${i%.icns}.icns" ] || fail "Info.plist names document icon $i, missing from Contents/Resources"
done
extra=$(find "$APP" -mindepth 1 -maxdepth 1 ! -name Contents -exec basename {} \;)
[ -z "$extra" ] || fail "unexpected item(s) at the .app root: $extra"
stray=$(find "$APP/Contents" -maxdepth 2 -name '*.bundle' ! -path "$RES/*" || true)
[ -z "$stray" ] || fail "resource bundle(s) outside Contents/Resources: $stray"
echo "layout ok: executable, llama.framework, ${#ICONS[@]} document icons, owl art, AI files and launcher in Contents/Resources"

# 2. Hide the build machine's fallbacks.
paths=$(strings -a "$EXE" | grep -E '^/.+/Sources/Cedric(App|AI|Core)/.+\.swift$' || true)
ROOTS=$( { printf '%s\n' "$paths" | sed -E -n 's#^(/.+)/Sources/Cedric(App|AI|Core)/.*#\1#p'; echo "$HERE"; } | sort -u)
echo "checkout root(s) compiled in: $(printf '%s\n' "$paths" | sed -E -n 's#^(/.+)/Sources/Cedric(App|AI|Core)/.*#\1#p' | sort -u | tr '\n' ' ')"
TARGETS=()
while IFS= read -r r; do
    [ -n "$r" ] || continue
    TARGETS+=("$r/Resources" "$r/.build")
done <<<"$ROOTS"
while IFS= read -r b; do
    [ -n "$b" ] && TARGETS+=("$b")
done < <(strings -a "$EXE" | grep -E '^/.+\.bundle$' | sort -u || true)
for d in "${TARGETS[@]}"; do
    [ ! -e "$d.smoke-hidden" ] || fail "$d.smoke-hidden exists (an interrupted earlier run?). Restore it: mv '$d.smoke-hidden' '$d'"
    case "$d" in "$TMP"/*) continue ;; esac
    if [ -e "$d" ]; then
        mv "$d" "$d.smoke-hidden"
        HIDDEN+=("$d")
        echo "hid build-machine fallback $d (restored on exit)"
    fi
done
for d in "${TARGETS[@]}"; do [ ! -e "$d" ] || fail "fallback path still exists during the smoke: $d"; done

ENV_CLEAN=(env)
for v in $(env | sed -n 's/^\(CEDRIC_[A-Z_]*\)=.*/\1/p'); do ENV_CLEAN+=(-u "$v"); done
ENV_CLEAN+=(CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1)

# Every process name a crash report from this zip could carry: the owl's
# and the app's names, each app-like bundle's (*/Contents/Info.plist)
# CFBundleExecutable and CFBundleName, and every file in a Contents/MacOS
# folder. Not framework names: a crash inside llama.framework is reported
# under the process that loaded it (Cedric), and a bare "llama" would
# also match another program's llama-*.ips (llama-server, llama-cli).
NAMES=(Cedric CedricApp Owlink)
while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(
    {
        find "$APP" -name Info.plist -path '*/Contents/Info.plist' -type f -print0 | while IFS= read -r -d '' pl; do
            plutil -extract CFBundleExecutable raw -o - "$pl" 2>/dev/null || true
            plutil -extract CFBundleName raw -o - "$pl" 2>/dev/null || true
        done
        find "$APP" -path '*/Contents/MacOS/*' -type f -exec basename {} \;
    } | sort -u)
echo "crash-report names: $(printf '%s\n' "${NAMES[@]}" | sort -u | paste -sd ' ' -)"
REPORT_DIRS=("$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports)
# Test-only override (see the top); unset in the release workflow.
if [ -n "${SMOKE_REPORT_DIRS:-}" ]; then
    IFS=: read -r -a REPORT_DIRS <<< "$SMOKE_REPORT_DIRS"
    echo "note: SMOKE_REPORT_DIRS set; crash reports read only from: ${REPORT_DIRS[*]}"
fi
# "basename<TAB>path" for every report named after one of NAMES, sorted.
matching_reports() {
    local d f base n
    for d in "${REPORT_DIRS[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r -d '' f; do
            base=${f##*/}
            for n in "${NAMES[@]}"; do
                case "$base" in "$n"[-_.]*) printf '%s\t%s\n' "$base" "$f"; break ;; esac
            done
        done < <(find "$d" \( -name '*.ips' -o -name '*.crash' \) -type f -print0 2>/dev/null)
    done | sort
}
BEFORE="$TMP/reports-before"
matching_reports | cut -f1 | sort -u > "$BEFORE"
echo "crash reports before the launch: $(wc -l < "$BEFORE" | tr -d ' ') matching"
# New: a basename not in BEFORE. The list is read in awk's BEGIN, not as
# its first file: with NR == FNR an empty list (a clean runner) would
# swallow every new report.
new_reports() {
    matching_reports | awk -F '\t' -v before="$BEFORE" '
        BEGIN { while ((getline l < before) > 0) seen[l] = 1; close(before) }
        !($1 in seen) { print $2 }' | paste -sd ' ' -
}
# Waits up to N s for any new report (ReportCrash can take several
# seconds); returns as soon as one shows up.
wait_for_report() { # seconds
    local i
    for i in $(seq 1 $(($1 * 4))); do
        [ -z "$(new_reports)" ] || return 0
        sleep 0.25
    done
}
CRASH_WAIT=10

# 3. llama.framework and the build kind.
out=$("${ENV_CLEAN[@]}" CEDRIC_LLAMA_CHECK=1 perl -e 'alarm shift; exec @ARGV' 30 "$EXE" -ApplePersistenceIgnoreState YES 2>"$TMP/llama-stderr") || {
    rc=$?; wait_for_report $CRASH_WAIT; cat "$TMP/llama-stderr" >&2
    fail "CEDRIC_LLAMA_CHECK run exited $rc: $out $(new_reports)"; }
grep -qx "llama: ok" <<<"$out" || fail "llama.framework did not load: $out"
hooks=$(sed -n 's/^dev hooks: //p' <<<"$out")
if [ "$hooks" != off ] && [ $ALLOW_CHECK = 0 ]; then fail "dev hooks: ${hooks:-not reported} (a check build must not ship)"; fi
echo "llama ok: llama.framework loads from Contents/Frameworks; dev hooks: $hooks"

# 4. A real launch.
"${ENV_CLEAN[@]}" "$EXE" -ApplePersistenceIgnoreState YES >"$TMP/stdout" 2>"$TMP/stderr" &
PID=$!
echo "launched pid $PID; watching for ${SECONDS_UP}s"
for _ in $(seq 1 $((SECONDS_UP * 4))); do
    if ! kill -0 "$PID" 2>/dev/null; then
        rc=0; wait "$PID" || rc=$?; PID=""
        wait_for_report $CRASH_WAIT
        echo "--- stderr ---" >&2; tail -40 "$TMP/stderr" >&2
        crash=$(new_reports)
        fail "Owlink exited within ${SECONDS_UP}s (exit $rc)${crash:+; crash report(s): $crash}"
    fi
    sleep 0.25
done
# The Quit, under an alarm: an osascript that hangs (an Automation prompt)
# can't hold the smoke. Its exit code and output are kept for the report.
QUIT_RC=0
with_alarm 10 osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($PID); (!a || a.isNil()) ? 'no NSRunningApplication for pid $PID' : 'terminate returned ' + a.terminate" \
    >"$TMP/quit.out" 2>"$TMP/quit.err" || QUIT_RC=$?
QUIT_NOTE=""; [ "$QUIT_RC" != 142 ] || QUIT_NOTE=" (its 10 s alarm fired)"
QUIT_SAID="osascript exit $QUIT_RC$QUIT_NOTE; stdout: $(tr '\n' ' ' < "$TMP/quit.out"); stderr: $(tr '\n' ' ' < "$TMP/quit.err")"
[ "$QUIT_RC" = 0 ] || echo "note: the Quit event's osascript failed: $QUIT_SAID" >&2
quit=0
for _ in $(seq 1 32); do kill -0 "$PID" 2>/dev/null || { quit=1; break; }; sleep 0.25; done
if [ $quit = 0 ]; then
    kill -9 "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
    fail "Owlink was up ${SECONDS_UP}s but did not quit within 8 s of a Quit event. The quit Apple Event may not have been delivered (Automation/TCC), or the app ignored it (a prompt?). $QUIT_SAID"
fi
rc=0; wait "$PID" || rc=$?; PID=""
[ $rc = 0 ] || fail "Owlink quit with exit code $rc"
echo "launch ok: up ${SECONDS_UP}s, quit cleanly on a Quit event (exit 0; $QUIT_SAID)"

# 5. Crash reports (any run above, a helper's, or a crash on quit).
wait_for_report $CRASH_WAIT
crash=$(new_reports)
[ -z "$crash" ] || fail "new crash report(s): $crash"

NHIDDEN=${#HIDDEN[@]}
restore
[ $RESTORE_FAILED = 0 ] || fail "could not restore every hidden path (see above)"
echo "SMOKE PASS: $(basename "$ZIP") unzipped fresh; Owlink ran ${SECONDS_UP}s and quit cleanly with ${NHIDDEN} build-machine fallback path(s) hidden; llama.framework loads; no crash report"

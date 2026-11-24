#!/bin/bash
# Big log check: generates a 55 MiB log of ordinary ~100-byte lines (the
# 0.5.2 crash: any text file past 25 M characters crashed in TextKit
# layout on macOS 26), opens it in a check build with CEDRIC_CHECK=bigfile
# (BigFileCheck.swift: large mode without chunks, layout at the top and
# the end, typing, a pasted 30,000-character line turning chunks on) and
# fails on a FAIL line, no result, or a new Cedric*.ips crash report.
# The log is generated each run in a temp folder, never stored in git.
#
#   Scripts/bigfile-check.sh [--mib N] [APP]    default 55 MiB, "dist/Owlink.app"
#
# APP must be a check build (Scripts/bundle-app.sh, not --release); the
# shipping zip's smoke test (Scripts/smoke-launch.sh) has no dev switches
# to open a file with. Never touches the real session. Needs a GUI
# session (works with the screen locked).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Owlink.app"
MIB=55
while [ $# -gt 0 ]; do
    case "$1" in
        --mib) MIB=$2; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) APP=${1%/} ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
W=$(mktemp -d "${TMPDIR:-/tmp}/cedric-bigfile.XXXXXX")
trap 'rm -rf "$W"' EXIT
LOG="$W/big.log"
python3 -I - "$LOG" "$MIB" <<'PY'
import sys
path, mib = sys.argv[1], int(sys.argv[2])
target = mib * 1024 * 1024
with open(path, "w") as f:
    n = i = 0
    while n < target:
        line = "2026-11-24T01:36:37.%06dZ INFO  worker-%02d request id=%08x status=200 bytes=%6d path=/api/v1/items\n" % (
            i % 1000000, i % 32, i, (i * 7919) % 999999)
        f.write(line); n += len(line); i += 1
PY
echo "== big.log: $(wc -c < "$LOG" | tr -d ' ') bytes, $(wc -l < "$LOG" | tr -d ' ') lines"

REPORTS=~/Library/Logs/DiagnosticReports
MARK="$W/mark"
: > "$MARK"
sleep 1   # reports from before this point stay older than MARK
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$W/out"
out=$(env CEDRIC_CHECK=bigfile CEDRIC_BIGFILE="$LOG" perl -e 'alarm 240; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null || true)
echo "$out" | grep -E "^check:" || true
sleep 3   # let ReportCrash write the .ips
crash=$(find "$REPORTS" -maxdepth 1 -name 'Cedric*.ips' -newer "$MARK" 2>/dev/null || true)
fail=0
[ -z "$crash" ] || { echo "bigfile-check: new crash report(s): $crash" >&2; fail=1; }
echo "$out" | grep -q "check: done .* 0 failed" || { echo "bigfile-check: the check failed or didn't finish" >&2; fail=1; }
[ $fail = 0 ] && echo "bigfile-check: PASS" || echo "bigfile-check: FAILED" >&2
exit $fail

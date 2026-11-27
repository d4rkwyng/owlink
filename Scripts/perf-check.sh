#!/bin/bash
# Big-document performance check: Derek's kind of file (one 636,293-character
# base64 line, no newline: a game add-on import string) and a 6 MB
# many-line file. Generates them (his own file is never committed), opens
# each with CEDRIC_PERF_BIG (LargeDocPerf.swift) with the owl on, and fails
# when a number is over its threshold:
#
#   first window (open)         < 300 ms
#   keystroke, median           <  16 ms   (start, middle and end of the line)
#   scripted scroll, worst step <  50 ms, and it never snaps back
#   idle CPU with the owl on    <   3 %
#
#   Scripts/perf-check.sh [--file PATH] [APP]     default "dist/Owlink.app"
#
# CEDRIC_PERF_WRITING=1 runs it with View › Writing Mode on (typewriter
# scrolling and Focus) in each file.
#
# Needs a GUI session (works with the screen locked). Numbers from a
# loaded machine can be noisy: run it again before believing a failure.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Owlink.app"
FILE=
while [ $# -gt 0 ]; do
    case "$1" in
        --file) FILE=$2; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) APP=${1%/} ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
. Scripts/check-env.sh
cedric_isolate "$W"
if [ -z "$FILE" ]; then
    FILE="$W/long-line.txt"
    head -c 477300 /dev/urandom | base64 | tr -d '\n' | head -c 636293 > "$FILE"
fi
python3 - "$W/many-lines.txt" <<'PY'
import sys, random
random.seed(7)
with open(sys.argv[1], "w") as f:
    n = 0
    while n < 6_200_000:
        line = "2026-11-17 12:00:%02d INFO request %d took %d ms\n" % (n % 60, n, random.randint(1, 900))
        f.write(line); n += len(line)
PY
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1
fail=0
check() { # name value limit
    local ok
    ok=$(awk -v v="$2" -v l="$3" 'BEGIN { print (v < l) ? 1 : 0 }')
    if [ "$ok" = 1 ]; then echo "  PASS $1 = $2 (< $3)"; else echo "  FAIL $1 = $2 (limit $3)"; fail=1; fi
}
for f in "$FILE" "$W/many-lines.txt"; do
    echo "== $(basename "$f") ($(wc -c < "$f" | tr -d ' ') bytes)"
    out=$(env CEDRIC_PERF_BIG="$f" CEDRIC_OWL=1 perl -e 'alarm 120; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null || true)
    echo "$out" | grep "^perf:" | sed 's/^/  /'
    m() { echo "$out" | sed -n "s/^metric $1=//p"; }
    [ -n "$(m open_total_ms)" ] || { echo "  FAIL no metrics (crashed?)"; fail=1; continue; }
    check open_total_ms "$(m open_total_ms)" 300
    for p in start middle end; do check "type_${p}_median_ms" "$(m type_${p}_median_ms)" 16; done
    check scroll_max_ms "$(m scroll_max_ms)" 50
    check scroll_backsteps "$(m scroll_backsteps)" 1
    check idle_cpu_pct "$(m idle_cpu_pct)" 3
    echo "$out" | grep "^metric" | sed 's/^metric /  /' > "$W/$(basename "$f").metrics"
done
[ $fail = 0 ] && echo "perf-check: all within limits" || echo "perf-check: FAILED" >&2
exit $fail

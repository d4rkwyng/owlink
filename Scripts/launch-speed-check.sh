#!/bin/bash
# Launch speed: times Owlink's cold launch (the app not running; the file
# cache warm after the first run) in three scenarios and prints the median
# of each phase over N runs, in ms since the process started (kernel start
# time, so dyld and static initialisers count):
#
#   empty     no saved session: one new untitled tab
#   restore   a saved session: 8 tabs in one window (6 files of 20 KB to
#             1 MB, 2 untitled tabs with unsaved buffers)
#   medium    no session, a 500 KB Swift file opened at launch
#   markdown  no session, a 200 KB Markdown file opened at launch (the
#             Context Bar and readable width built)
#
# Columns (CEDRIC_LAUNCH_TRACE, see Sources/CedricApp/LaunchTrace.swift):
#   main         main.swift reached (before it: dyld, static init)
#   did_finish   applicationDidFinishLaunching entered
#   tabs_ready   tabs built and ordered in
#   first_frame  first frame committed with a window on screen
#   key_drawn    a key posted at first_frame was typed and drawn
#   idle         deferred launch work drained
#
#   Scripts/launch-speed-check.sh [--runs N] [--limit-frame MS] [--limit-key MS] [APP]
#
# Default 7 runs, "dist/Owlink.app". With --limit-*, exits 1 when a
# scenario's median first_frame / key_drawn is over the limit. Uses
# throwaway session directories; never touches the real session. Needs a
# GUI session (works with the screen locked).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Owlink.app"
RUNS=7
LIMIT_FRAME=
LIMIT_KEY=
while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS=$2; shift ;;
        --limit-frame) LIMIT_FRAME=$2; shift ;;
        --limit-key) LIMIT_KEY=$2; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) APP=${1%/} ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
. Scripts/check-env.sh
cedric_require_check_build "$APP"
BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/Cedric
W=$(mktemp -d)
[ -n "${KEEP_W:-}" ] && echo "work dir: $W" || trap 'rm -rf "$W"' EXIT
cedric_isolate "$W"

# Test files and the saved session (session.json format: CedricCore/Session.swift).
python3 - "$W" <<'PY'
import sys, os, json, uuid, random
w = sys.argv[1]
random.seed(3)
def fill(name, target, line):
    p = os.path.join(w, name)
    with open(p, "w") as f:
        n = i = 0
        while n < target:
            s = line(i); f.write(s); n += len(s); i += 1
    return p
swift = lambda i: ("func f%d(_ x: Int) -> Int {\n    // comment %d\n    let s = \"value \\(x)\"\n    return x * %d + s.count\n}\n" % (i, i, i % 97))
medium = fill("medium.swift", 500_000, swift)
# A Markdown document opened on its own: the Context Bar (on by default
# since 0.4.0) and readable width are built at launch.
fill("medium.md", 200_000, lambda i: "## Section %d\n\nSome *prose* with `code`, a [link](https://example.com/%d) and **bold** words.\n\n- item %d\n- [ ] task %d\n\n" % (i, i, i, i))
files = [
    fill("a.swift", 120_000, swift),
    fill("b.json", 1_000_000, lambda i: '  {"id": %d, "name": "row %d", "tags": ["a", "b"], "ok": true},\n' % (i, i)),
    fill("c.md", 40_000, lambda i: "## Heading %d\n\nSome *prose* with `code` and a [link](https://example.com/%d).\n\n" % (i, i)),
    fill("d.py", 80_000, lambda i: "def g%d(x):\n    \"\"\"doc %d\"\"\"\n    return [y * %d for y in range(x)]\n\n" % (i, i, i % 13)),
    fill("e.js", 60_000, lambda i: "export function h%d(a) { const s = `t${a}`; return s.length + %d; } // %d\n" % (i, i, i)),
    fill("f.log", 20_000, lambda i: "2026-11-18 10:00:%02d INFO request %d took %d ms\n" % (i % 60, i, random.randint(1, 900))),
]
sess = os.path.join(w, "restore-session"); os.makedirs(sess)
tabs = []
for i, p in enumerate(files):
    tabs.append({"id": str(uuid.uuid4()).upper(), "path": p, "hasBuffer": False, "encoding": "utf8", "lineEnding": "lf",
                 "selectionLocation": 0, "selectionLength": 0, "topLine": 40 if i == 1 else 0})
for i in range(2):
    tid = str(uuid.uuid4()).upper()
    with open(os.path.join(sess, tid + ".txt"), "w") as f:
        f.write(("unsaved notes %d\n" % i) * 400)
    tabs.append({"id": tid, "untitledName": "Untitled" if i == 0 else "Untitled 2", "hasBuffer": True, "encoding": "utf8",
                 "lineEnding": "lf", "selectionLocation": 0, "selectionLength": 0, "topLine": 0})
json.dump({"version": 1, "untitledCounter": 0, "windows": [{"tabs": tabs, "selectedTab": 0}]},
          open(os.path.join(sess, "session.json"), "w"))
PY
# The encoding/lineEnding raw values must match CedricCore; check the session decodes.
n=$(env CEDRIC_SESSION_DIR="$W/restore-session" CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 perl -e 'alarm 60; exec @ARGV' \
    "$BIN_ABS" -ApplePersistenceIgnoreState YES 2>/dev/null | grep -c '^tab:' || true)
[ "$n" = 8 ] || { echo "launch-speed-check: the test session restored $n tabs, not 8" >&2; exit 1; }

run_scenario() { # name, env...
    local name=$1; shift
    : > "$W/$name.out"
    for i in $(seq 1 "$RUNS"); do
        env "$@" CEDRIC_LAUNCH_TRACE=1 CEDRIC_NO_SESSION_SAVE=1 perl -e 'alarm 60; exec @ARGV' \
            "$BIN_ABS" -ApplePersistenceIgnoreState YES 2>/dev/null | sed -n "s/^launch /run$i /p" >> "$W/$name.out" || true
        sleep 1
    done
}
run_scenario empty CEDRIC_SESSION_DIR="$W/empty-session"
run_scenario restore CEDRIC_SESSION_DIR="$W/restore-session"
run_scenario medium CEDRIC_SESSION_DIR="$W/empty-session" CEDRIC_NO_RESTORE=1 CEDRIC_OPEN="$W/medium.swift"
run_scenario markdown CEDRIC_SESSION_DIR="$W/empty-session" CEDRIC_NO_RESTORE=1 CEDRIC_OPEN="$W/medium.md"

python3 - "$W" "$RUNS" "${LIMIT_FRAME:-0}" "${LIMIT_KEY:-0}" <<'PY'
import sys, os, statistics
w, runs, lf, lk = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
cols = ["main", "did_finish", "tabs_ready", "first_frame", "key_drawn", "idle"]
print("%-8s %s   (median ms of %d runs since process start)" % ("", " ".join("%11s" % c for c in cols), runs))
fail = 0
for name in ["empty", "restore", "medium", "markdown"]:
    vals = {}
    bad = set()
    for line in open(os.path.join(w, name + ".out")):
        run, kv = line.split()
        k, v = kv.split("=")
        if k in ("key_not_inserted", "no_window"): bad.add(run)
        vals.setdefault(k, []).append(float(v))
    med = {c: statistics.median(vals[c]) if c in vals else None for c in cols}
    n = len(vals.get("key_drawn", []))
    print("%-8s %s   n=%d%s" % (name, " ".join("%11s" % ("-" if med[c] is None else "%.0f" % med[c]) for c in cols), n,
                                 "  FAILED RUNS: %d" % (runs - n) if n < runs else ""))
    if n < runs or bad: fail = 1
    if lf and (med["first_frame"] or 1e9) > lf: print("  FAIL %s first_frame over %.0f ms" % (name, lf)); fail = 1
    if lk and (med["key_drawn"] or 1e9) > lk: print("  FAIL %s key_drawn over %.0f ms" % (name, lk)); fail = 1
sys.exit(fail)
PY

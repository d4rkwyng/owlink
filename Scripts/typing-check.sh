#!/bin/bash
# Typing smoke check: real key events (NSEvent keyDown through the window)
# into a new untitled tab and an opened file, in every theme (System light
# and dark, Light, Dark, Tankard, Dracula), then the pixels under the typed
# glyphs are sampled: typed text must stand out from the background
# immediately and after highlighting. Also Return/Tab, caret and selection
# contrast, paste (CRLF), undo/redo, Replace All, find-field typing, a
# theme switch mid-typing, IME marked text, select-all + delete, and typing
# at the end of a 10 MB file. See Sources/CedricApp/TypingCheck.swift.
# Throwaway session; works with the screen locked.
#
#   Scripts/typing-check.sh [APP] [SHOTS_DIR]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/Owlink.app}"
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
. Scripts/check-env.sh
cedric_require_check_build "$APP"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cedric_isolate "$W"
printf 'func hello() {\n    print("hi")\n}\n' > "$W/file.swift"
python3 - "$W/big.json" <<'PY'
import sys
row = '  {"id": 123456, "name": "Cedric typing check", "tags": ["a", "b"], "ok": true},\n'
with open(sys.argv[1], "w") as f:
    f.write("[\n" + row * (10_000_000 // len(row)) + "  {}\n]\n")
PY
SHOTS=${2:-}
[ -n "$SHOTS" ] && mkdir -p "$SHOTS"
set +e
env CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_TYPE_CHECK=1 \
    CEDRIC_TYPE_CHECK_FILE="$W/file.swift" CEDRIC_TYPE_CHECK_BIG="$W/big.json" ${SHOTS:+CEDRIC_TYPE_CHECK_SHOTS="$SHOTS"} \
    "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null | grep '^typecheck:' > "$W/out.txt"
status=${PIPESTATUS[0]}
set -e
grep -v ' PASS ' "$W/out.txt" || true
echo "typing-check: $(grep -c ' PASS ' "$W/out.txt") passed, $(grep -c ' FAIL ' "$W/out.txt") failed"
[ "$status" = 0 ] && grep -q 'done failures=0' "$W/out.txt"

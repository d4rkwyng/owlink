#!/bin/bash
# Whole-window render check (RenderDump.check): every theme, a 900x670
# window, the owl turned on as the menu does, typed text; the whole window
# is rendered from its CALayer tree and with cacheDisplay on the frame
# view, and the typed text, line numbers, owl and editor background are
# checked in those images. Catches a view painting over the editor (the
# status bar did, test build 2), which per-view renders can't see.
# Throwaway session; works with the screen locked.
#
#   Scripts/render-check.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product CedricApp >/dev/null
BIN=$(swift build --show-bin-path)/CedricApp
OUT=${1:-$(mktemp -d -t cedric-render-check)}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
. Scripts/check-env.sh
cedric_isolate "$W"
set +e
CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_OWL=0 CEDRIC_RENDER_CHECK="$OUT" \
    "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null | grep '^rendercheck:' > "$W/out.txt"
status=${PIPESTATUS[0]}
set -e
grep -v ' PASS ' "$W/out.txt" || true
echo "render-check: $(grep -c ' PASS ' "$W/out.txt") passed, $(grep -c ' FAIL ' "$W/out.txt") failed; images in $OUT"
[ "$status" = 0 ] && grep -q 'done failures=0' "$W/out.txt"

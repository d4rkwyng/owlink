#!/bin/bash
# The owl's local-AI check (AICheck.swift), in process with real NSEvents:
# opens the AI settings sheet, enables it and saves, goes to line 200 of a
# 260-line Swift file (past the 8 KB context cap), types an off-by-one,
# checks the thinking pose, the bubble's "local:<model>" hint and its
# document range, and snapshots each step.
#
#   Scripts/ai-check.sh [out-dir]          fake provider, no server (CI-safe)
#   Scripts/ai-check.sh --live MODEL [out] against LM Studio on this Mac
#
# Settings go to a throwaway UserDefaults suite; nothing real is changed.
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL=""
if [ "${1:-}" = "--live" ]; then MODEL=$2; shift 2; fi
swift build --product CedricApp >/dev/null 2>&1 || swift build --product CedricApp
BIN=$(swift build --show-bin-path)/CedricApp
OUT=${1:-$(mktemp -d -t cedric-ai-check)}
WORK=$(mktemp -d -t cedric-ai-work)
SUITE="cedric-ai-check-$$"
trap 'rm -rf "$WORK"; defaults delete "$SUITE" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$SUITE.plist"' EXIT
. Scripts/check-env.sh
cedric_isolate "$WORK"
python3 - "$WORK/Inventory.swift" <<'PY'
import sys
lines = ["// Inventory helpers: filler so the file is well over the owl's 8 KB context cap."]
for i in range(1, 260):
    lines.append(f"let shelf{i:03d} = Shelf(id: {i}, label: \"aisle {i % 17}\", capacity: {i * 3 % 50})")
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
if [ -n "$MODEL" ]; then
    MODE=(CEDRIC_AI_CHECK_MODEL="$MODEL" CEDRIC_AI_PAUSE=2 CEDRIC_AI_MIN_IDLE=2 CEDRIC_AI_INTERVAL=5 CEDRIC_AI_TIMEOUT=45)
else
    MODE=(CEDRIC_AI_FAKE=1.5 CEDRIC_AI_PAUSE=1 CEDRIC_AI_MIN_IDLE=1 CEDRIC_AI_INTERVAL=1 CEDRIC_AI_TIMEOUT=2)
fi
status=0
env CEDRIC_SESSION_DIR="$WORK/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
    CEDRIC_OPEN="$WORK/Inventory.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_SOURCE=rules \
    CEDRIC_AI_DEFAULTS="$SUITE" CEDRIC_SNAPSHOT_SIZE=900x520 CEDRIC_AI_CHECK="$OUT" "${MODE[@]}" \
    "$BIN" 2>/dev/null | grep '^aicheck:' || status=1
grep -q . <(ls "$OUT"/*.png 2>/dev/null) || status=1
echo "ai-check: snapshots in $OUT"
exit $status

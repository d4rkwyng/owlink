#!/bin/bash
# Image tabs and Office (Quick Look) tabs, end to end, in the running app
# (ImageCheck.swift): makes its own files (PNG with transparency, a JPEG
# turned by EXIF, an animated GIF and a HEIC with ImageIO; a 12000×12000
# PNG; a .docx with NSAttributedString; an .xlsx zipped from hand-written
# parts), opens them, and checks the status bar (pixel size, file size,
# format, colour space, zoom), fit, zoom (⌘= ⌘- ⌘0 ⌘9), pan, the
# checkerboard, menus that must be off, Copy, Open in <default app>,
# Print, GIF play / pause, magic-byte detection, cedric -w, Reopen Closed
# Tab, drops, a damaged file; Open as Text (.docx) and Open Sheet as CSV
# (.xlsx); that no file is written; and that typing in a text tab isn't
# held up while the 12000×12000 PNG decodes (measured). Then it saves the
# session, relaunches, and checks the tabs come back at their zoom, the
# unselected ones not loaded until shown. Throwaway session; works with
# the screen locked.
#
#   Scripts/image-check.sh [--out DIR] [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-image-check
APP="dist/Owlink.app"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift ;;
        *) APP=$1 ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
mkdir -p "$OUT"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
. Scripts/check-env.sh
cedric_isolate "$W"
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_IMAGE_DIR="$W/images" CEDRIC_CHECK_OUT="$OUT" CEDRIC_THEME=${CEDRIC_THEME:-dark}
fail=0
run() { # name, extra env...
    local name=$1; shift
    echo "== $name"
    if ! env "$@" CEDRIC_CHECK=$name perl -e 'alarm 240; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
        | grep -E "^check:" | tee "$OUT/$name.txt"; then fail=1; fi
    grep -q "check: done .* 0 failed" "$OUT/$name.txt" || { echo "image-check: $name FAILED" >&2; fail=1; }
}
# First run: no restore, but the session is saved (for the second).
run image CEDRIC_NO_RESTORE=1
run imagerestore CEDRIC_NO_SESSION_SAVE=1
echo "image-check: $(cat "$OUT"/image.txt "$OUT"/imagerestore.txt | grep -c 'check: PASS') passed, $(cat "$OUT"/image.txt "$OUT"/imagerestore.txt | grep -c 'check: FAIL') failed; snapshots in $OUT"
exit $fail

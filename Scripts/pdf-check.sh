#!/bin/bash
# PDF tabs, end to end, in the running app (PDFCheck.swift): makes its own
# PDFs with Core Graphics (no binary fixtures), opens them, and checks the
# page count, find (⌘F, ⌘G, ⇧⌘G, Match Case), select and copy, Go to Page
# (⌘L), zoom (⌘= ⌘- ⌘0 ⌘9), the thumbnails sidebar, Open as Text, menus
# that must be off (save, edit), magic-byte detection, cedric file.pdf:N
# and -w, Reopen Closed Tab, drops, an encrypted PDF's password sheet and a
# damaged file. Then it saves the session, relaunches, and checks the PDF
# tabs come back on their page and zoom, the unselected one not loaded
# until shown. Last, the floating reader controls (pdfoverlay): every
# control, ←/→ and Page Up/Down, the page field, fit page, view-only
# rotation, the auto-hide and Reduce Motion. Throwaway session; works
# with the screen locked.
#
#   Scripts/pdf-check.sh [--out DIR] [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-pdf-check
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
. Scripts/check-env.sh
cedric_require_check_build "$APP"
mkdir -p "$OUT"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cedric_isolate "$W"
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_PDF_DIR="$W/pdf" CEDRIC_CHECK_OUT="$OUT" CEDRIC_THEME=${CEDRIC_THEME:-dark}
fail=0
run() { # name, extra env...
    local name=$1; shift
    echo "== $name"
    if ! env "$@" CEDRIC_CHECK=$name perl -e 'alarm 120; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
        | grep -E "^check:" | tee "$OUT/$name.txt"; then fail=1; fi
    grep -q "check: done .* 0 failed" "$OUT/$name.txt" || { echo "pdf-check: $name FAILED" >&2; fail=1; }
}
# First run: no restore, but the session is saved (for the second).
run pdf CEDRIC_NO_RESTORE=1
run pdfrestore CEDRIC_NO_SESSION_SAVE=1
# The floating reader controls (PDFOverlay): its own throwaway session.
run pdfoverlay CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1
echo "pdf-check: $(cat "$OUT"/pdf.txt "$OUT"/pdfrestore.txt "$OUT"/pdfoverlay.txt | grep -c 'check: PASS') passed, $(cat "$OUT"/pdf.txt "$OUT"/pdfrestore.txt "$OUT"/pdfoverlay.txt | grep -c 'check: FAIL') failed; snapshots in $OUT"
exit $fail

#!/bin/bash
# Folder sidebar click speed (0.6.1, Derek: "clicking on other files it
# seemed kind of slow"). Runs CEDRIC_CHECK=sidebarclick
# (SidebarClickCheck.swift) in a check build: a research folder like his
# (Markdown notes, a 300 KB note, a 2 MB GPX track, wardrive logs of 2, 8,
# 30 and 120 MB, pcap captures of 5 and 60 MB) written in a temp folder,
# opened in the sidebar and clicked with real mouse events. Prints the
# `metric` and `phase` lines and fails when a median is over its limit:
#
#   click to text shown, median     per kind and mode (LIMITS below)
#   longest main-thread stall       per kind and mode (LIMITS below)
#
# The limits are about 3x the 0.6.1 numbers on an M4 Mac (see
# CHANGELOG.md, 0.6.1), so a loaded machine doesn't fail it. TIMING
# SENSITIVE: run it on a quiet machine, and again before believing a
# failure.
#
#   Scripts/sidebar-click-check.sh [--repeats N] [--kinds a,b] [APP]   default "dist/Owlink.app"
#
# APP must be a check build (Scripts/bundle-app.sh, not --release); build
# it with the release configuration (bundle-app.sh does) since a debug
# build is not representative. Needs a GUI session (works with the screen
# locked). Never touches the real session; the folder (about 1.4 GB) is
# removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Owlink.app"
REPEATS=7
KINDS=
while [ $# -gt 0 ]; do
    case "$1" in
        --repeats) REPEATS=$2; shift ;;
        --kinds) KINDS=$2; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) APP=${1%/} ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
. Scripts/check-env.sh
cedric_require_check_build "$APP"
W=$(mktemp -d "${TMPDIR:-/tmp}/cedric-sidebarclick.XXXXXX")
trap 'rm -rf "$W"' EXIT
cedric_isolate "$W"
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$W/out"
export TMPDIR="$W/"
out=$(env CEDRIC_CHECK=sidebarclick CEDRIC_OWL=1 CEDRIC_SIDEBARCLICK_REPEATS="$REPEATS" ${KINDS:+CEDRIC_SIDEBARCLICK_KINDS="$KINDS"} \
    perl -e 'alarm 1200; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null || true)
echo "$out" | grep -E "^(sidebarclick:|check: (FAIL|note|done))" || true
echo "$out" | grep -E "^(metric|phase) " || true

# Limits in ms: kind_mode shown-median stall-max.
LIMITS="
md_small_cold 60 60
md_small_reopen 60 60
md_small_switch 60 60
md_small_dblclick 60 60
md_300k_cold 100 100
md_300k_reopen 100 100
md_300k_switch 60 60
gpx_2m_cold 150 150
gpx_2m_reopen 150 150
gpx_2m_switch 60 60
log_2m_cold 150 150
log_2m_reopen 150 150
log_2m_switch 60 60
log_8m_cold 300 300
log_8m_reopen 300 300
log_8m_switch 60 60
log_30m_cold 1500 300
log_30m_reopen 1500 300
log_30m_switch 60 60
log_120m_cold 4000 600
log_120m_reopen 4000 600
log_120m_switch 60 60
pcap_5m_cold 100 100
pcap_5m_reopen 100 100
pcap_5m_switch 60 60
pcap_60m_cold 600 100
pcap_60m_reopen 600 100
pcap_60m_switch 60 60
"
fail=0
m() { echo "$out" | sed -n "s/^metric $1=//p"; }
check() { # name value limit
    local ok
    ok=$(awk -v v="$2" -v l="$3" 'BEGIN { print (v < l) ? 1 : 0 }')
    if [ "$ok" = 1 ]; then echo "  PASS $1 = $2 (< $3)"; else echo "  FAIL $1 = $2 (limit $3)"; fail=1; fi
}
echo "$out" | grep -q "check: done .* 0 failed" || { echo "  FAIL the check failed or didn't finish"; fail=1; }
while read -r key shown stall; do
    [ -n "$key" ] || continue
    v=$(m "${key}_shown_median_ms")
    if [ -z "$v" ]; then
        # Not run (--kinds), or missing.
        [ -n "$KINDS" ] && continue
        echo "  FAIL $key: no metrics"; fail=1; continue
    fi
    check "${key}_shown_median_ms" "$v" "$shown"
    check "${key}_stall_max_ms" "$(m "${key}_stall_max_ms")" "$stall"
done <<< "$LIMITS"
[ $fail = 0 ] && echo "sidebar-click-check: all within limits" || echo "sidebar-click-check: FAILED" >&2
exit $fail

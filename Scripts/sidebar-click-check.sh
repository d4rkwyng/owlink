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
# The limits are about 3x the after-fix numbers measured on geonosis
# (M4 Pro, 2026-11-28; see scratch/061-sidebar-speed/perf/BEFORE-AFTER.md),
# so a loaded machine doesn't fail it. The 60 ms stall cap on small
# Markdown was too tight: creating the tab already takes about that long. TIMING
# SENSITIVE: run it on a quiet machine, and again before believing a
# failure.
#
#   Scripts/sidebar-click-check.sh [--repeats N] [--kinds a,b] [APP]   default "dist/Owlink.app"
#
# --kinds runs only the kinds named (the names in LIMITS below, without
# the mode: md_small, pcap_5m, ...). A name that is not a kind, or an
# empty list, fails at once, before the app is launched or a file is
# written: a typo measured nothing and used to pass. Every kind that was
# asked for (all of them without --kinds) must report both metrics for
# each of its modes; a missing one fails.
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
KINDS_GIVEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repeats) REPEATS=$2; shift ;;
        --kinds) [ $# -ge 2 ] || { echo "--kinds needs a list: a,b" >&2; exit 2; }; KINDS=$2; KINDS_GIVEN=1; shift ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) APP=${1%/} ;;
    esac
    shift
done
# Limits in ms: kind_mode shown-median stall-max.
LIMITS="
md_small_cold 180 210
md_small_reopen 180 210
md_small_switch 180 210
md_small_dblclick 180 210
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
# The kinds LIMITS knows (a key without its mode), and whether --kinds
# asked for one (all of them without --kinds).
KNOWN=$(echo "$LIMITS" | awk 'NF { sub(/_[a-z]+$/, "", $1); print $1 }' | sort -u)
asked() { [ "$KINDS_GIVEN" = 0 ] || case ",$KINDS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
if [ "$KINDS_GIVEN" = 1 ]; then
    bad=
    n=0
    IFS=, read -r -a names <<< "$KINDS"
    for k in ${names[@]+"${names[@]}"}; do
        n=$((n + 1))
        echo "$KNOWN" | grep -qxF -- "$k" || bad="$bad '$k'"
    done
    if [ $n = 0 ] || [ -n "$bad" ]; then
        if [ $n = 0 ]; then echo "sidebar-click-check: --kinds names no kind" >&2; else echo "sidebar-click-check: --kinds: no such kind:$bad" >&2; fi
        echo "  kinds: $(echo $KNOWN | tr ' ' ',')" >&2
        echo "sidebar-click-check: FAILED" >&2
        exit 1
    fi
fi
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

fail=0
m() { echo "$out" | sed -n "s/^metric $1=//p"; }
check() { # name value limit
    local ok
    ok=$(awk -v v="$2" -v l="$3" 'BEGIN { print (v < l) ? 1 : 0 }')
    if [ "$ok" = 1 ]; then echo "  PASS $1 = $2 (< $3)"; else echo "  FAIL $1 = $2 (limit $3)"; fail=1; fi
}
echo "$out" | grep -q "check: done .* 0 failed" || { echo "  FAIL the check failed or didn't finish"; fail=1; }
measured=0
while read -r key shown stall; do
    [ -n "$key" ] || continue
    # Not asked for (--kinds): nothing to require.
    asked "${key%_*}" || continue
    for metric in shown_median_ms stall_max_ms; do
        v=$(m "${key}_$metric")
        # Asked for and not measured is a failure, never a skip.
        if [ -z "$v" ]; then echo "  FAIL ${key}_$metric: no metric"; fail=1; continue; fi
        measured=$((measured + 1))
        if [ $metric = shown_median_ms ]; then check "${key}_$metric" "$v" "$shown"; else check "${key}_$metric" "$v" "$stall"; fi
    done
done <<< "$LIMITS"
[ $measured -gt 0 ] || { echo "  FAIL nothing was measured"; fail=1; }
[ $fail = 0 ] && echo "sidebar-click-check: all within limits" || echo "sidebar-click-check: FAILED" >&2
exit $fail

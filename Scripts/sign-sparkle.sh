#!/bin/bash
# Signs an embedded Sparkle.framework inside out, in the order Sparkle 2's
# documentation gives for re-signing it with your own identity: the XPC
# services, Autoupdate, Updater.app, then the framework. Never --deep.
# Downloader.xpc keeps its entitlements (--preserve-metadata=entitlements);
# nothing else gets any (Autoupdate's application-identifier is dropped,
# as Sparkle's instructions do).
#
#   Scripts/sign-sparkle.sh [--dry-run] <Sparkle.framework> <codesign command…>
#
#   Scripts/sign-sparkle.sh dist/Owlink.app/Contents/Frameworks/Sparkle.framework \
#       codesign --force --options runtime --timestamp -s "Developer ID Application: …"
#
# Used by Scripts/sign-adhoc.sh (bundle-app.sh's ad-hoc signing) and
# Scripts/release.sh (Developer ID). Sign the app itself afterwards.
set -euo pipefail
DRY=0
if [ "${1:-}" = --dry-run ]; then DRY=1; shift; fi
[ $# -ge 2 ] || { sed -n '2,15p' "$0" >&2; exit 2; }
FW=$1; shift
SIGN=("$@")
[ "${SIGN[0]}" = codesign ] || { echo "sign-sparkle.sh: the signing command must be codesign" >&2; exit 2; }
for a in "${SIGN[@]}"; do
    [ "$a" = --deep ] && { echo "sign-sparkle.sh: no --deep (each piece is signed on its own)" >&2; exit 2; }
done
B="$FW/Versions/B"
if [ $DRY = 0 ]; then
    [ -d "$FW" ] || { echo "sign-sparkle.sh: no $FW" >&2; exit 1; }
    for p in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
        [ -e "$B/$p" ] || { echo "sign-sparkle.sh: $FW lacks Versions/B/$p" >&2; exit 1; }
    done
fi
step() {
    local line
    line=$(printf '%q ' "$@")
    echo "+ ${line% }"
    [ $DRY = 1 ] || "$@"
}
step "${SIGN[@]}" "$B/XPCServices/Installer.xpc"
step "${SIGN[@]}" --preserve-metadata=entitlements "$B/XPCServices/Downloader.xpc"
step "${SIGN[@]}" "$B/Autoupdate"
step "${SIGN[@]}" "$B/Updater.app"
step "${SIGN[@]}" "$FW"

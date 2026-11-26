#!/bin/bash
# Ad-hoc signs an assembled Owlink.app inside out, for Scripts/bundle-app.sh
# (no identity, no Gatekeeper approval, no App Sandbox: an editor opens
# arbitrary files by path from the command line):
#  1. each nested framework, dylib, XPC service and app extension on its
#     own, deepest first (llama.framework; Sparkle.framework is left to 2);
#  2. a release build's Sparkle.framework in Sparkle's own order
#     (Scripts/sign-sparkle.sh; Downloader.xpc keeps its entitlements);
#  3. the app, once, so its seal covers everything as signed.
# Signing never uses --deep: it would re-sign every nested piece with the
# outer piece's options and drop their entitlements before step 2 could
# keep them. Verification does use --deep --strict.
#
#   Scripts/sign-adhoc.sh <Owlink.app>
set -euo pipefail
fail() { echo "sign-adhoc.sh: $*" >&2; exit 1; }
[ $# = 1 ] || { sed -n '2,14p' "$0" >&2; exit 2; }
APP=$1
[ -d "$APP/Contents/MacOS" ] || fail "$APP is not an app bundle"
HERE=$(cd "$(dirname "$0")" && pwd)
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SIGN=(codesign -s - --force)

nested=0
while IFS= read -r -d '' f; do
    "${SIGN[@]}" "$f"
    nested=$((nested + 1))
done < <(find "$APP/Contents" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) \
             -not -path "$SPARKLE_FW" -not -path "$SPARKLE_FW/*" -print0)
[ -d "$APP/Contents/Frameworks/llama.framework" ] || fail "no llama.framework in $APP"
[ $nested -ge 1 ] || fail "found no nested code to sign; llama.framework should be there"
if [ -d "$SPARKLE_FW" ]; then
    "$HERE/sign-sparkle.sh" "$SPARKLE_FW" "${SIGN[@]}"
fi
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

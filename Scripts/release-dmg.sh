#!/bin/bash
# The DMG, after Scripts/release.sh: puts the notarized, stapled
# dist/Owlink.app that release.sh made (the same bundle that is in the
# zip) into dist/Owlink-<version>.dmg with an /Applications alias
# (Scripts/make-dmg.sh), signs the DMG with the same Developer ID
# (secure timestamp), notarizes it, staples it, and checks it as
# Gatekeeper would for a download (spctl, open context), and the app on
# it (spctl, exec). The app is never rebuilt or re-signed here. Nothing is
# launched; Scripts/smoke-launch.sh does that with the DMG afterwards.
#
#   Scripts/release-dmg.sh [--dry-run] [--skip-notarize]
#
# Settings: as release.sh (CEDRIC_SIGN_ID, CEDRIC_NOTARY_PROFILE, or all of
# NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD in CI; CEDRIC_VERSION).
# Output: dist/Owlink-<version>.dmg, dist/notary-dmg-result.json and
# dist/notary-dmg-log.json (Apple's answer and log for the DMG).
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
NOTARIZE=1
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --skip-notarize) NOTARIZE=0 ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
        *) echo "release-dmg.sh: unknown option $a" >&2; exit 2 ;;
    esac
done

run() {
    local shown=() hide=0
    for w in "$@"; do
        if [ $hide = 1 ]; then shown+=("****"); hide=0; continue; fi
        shown+=("$(printf '%q' "$w")")
        [ "$w" = "--password" ] && hide=1
    done
    echo "+ ${shown[*]}"
    [ $DRY = 1 ] || "$@"
}
fail() { echo "release-dmg.sh: $*" >&2; exit 1; }

SOURCE_VERSION=$(sed -n 's/.*static let source = "\([^"]*\)".*/\1/p' Sources/CedricCore/Version.swift)
VERSION=${CEDRIC_VERSION:-$SOURCE_VERSION}
APP=dist/Owlink.app
DMG="dist/Owlink-${VERSION}.dmg"
[ $DRY = 1 ] || [ -d "$APP" ] || fail "no $APP: run Scripts/release.sh first"

# The app must be release.sh's finished one: signed and, when notarizing,
# stapled (so the DMG carries the ticketed app, not a second copy).
if [ $DRY = 0 ]; then
    codesign --verify --strict --deep "$APP" || fail "$APP's signature doesn't verify"
    [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION" ] \
        || fail "$APP is not version $VERSION"
    if [ $NOTARIZE = 1 ]; then
        xcrun stapler validate "$APP" || fail "$APP is not stapled: run Scripts/release.sh (without --skip-notarize) first"
    fi
fi

ID=${CEDRIC_SIGN_ID:-}
if [ -z "$ID" ]; then
    ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$ID" ]; then
    [ $DRY = 1 ] || fail 'no "Developer ID Application:" signing identity (or set CEDRIC_SIGN_ID; "-" with --skip-notarize for a local test)'
    ID="Developer ID Application: EXAMPLE (TEAMID)"
fi
[ "$ID" != "-" ] || [ $NOTARIZE = 0 ] || fail 'an ad-hoc signature cannot be notarized; add --skip-notarize'

NOTARY_ARGS=()
if [ $NOTARIZE = 1 ]; then
    if [ -n "${NOTARY_APPLE_ID:-}" ] || [ -n "${NOTARY_TEAM_ID:-}" ] || [ -n "${NOTARY_PASSWORD:-}" ]; then
        [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] \
            || fail "set all three of NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD, or none"
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
    else
        NOTARY_ARGS=(--keychain-profile "${CEDRIC_NOTARY_PROFILE:-cedric}")
    fi
fi

# 1. The image, checked (layout, the app's files and CDHash, its ticket).
run Scripts/make-dmg.sh "$APP" "$DMG"

# 2. Sign the DMG itself (no --options runtime: that is for code).
if [ "$ID" = "-" ]; then
    run codesign --force --sign - "$DMG"
else
    run codesign --force --sign "$ID" --timestamp "$DMG"
fi
run codesign --verify --strict "$DMG"

if [ $NOTARIZE = 0 ]; then
    echo "Signed but not notarized: $DMG"
    exit 0
fi

# 3. Notarize (with Apple's log kept, as release.sh does for the zip),
#    staple, validate.
RESULT=dist/notary-dmg-result.json
NOTARY_LOG=dist/notary-dmg-log.json
if [ $DRY = 1 ]; then
    run xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --output-format json
else
    rm -f "$RESULT" "$NOTARY_LOG"
    echo "+ xcrun notarytool submit $DMG ${NOTARY_ARGS[0]} … --wait --output-format json"
    SUBMIT_RC=0
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --output-format json | tee "$RESULT" || SUBMIT_RC=$?
    echo
    STATUS=$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)
    SUB_ID=$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)
    if [ -n "$SUB_ID" ]; then
        for i in 1 2 3; do
            if xcrun notarytool log "${NOTARY_ARGS[@]}" "$SUB_ID" "$NOTARY_LOG"; then
                echo "--- $NOTARY_LOG"; cat "$NOTARY_LOG"; echo; echo "---"; break
            fi
            [ $i = 3 ] || sleep 10
        done
    fi
    [ "$STATUS" = Accepted ] || fail "DMG notarization status: $STATUS (notarytool exit $SUBMIT_RC)"
fi
run xcrun stapler staple "$DMG"
run xcrun stapler validate "$DMG"

# 4. Gatekeeper, as for a download: the DMG (open, primary signature) and
#    the app on it (exec), mounted read-only at a private mount point.
run spctl -a -vv -t open --context context:primary-signature "$DMG"
if [ $DRY = 0 ]; then
    MNT=$(mktemp -d /tmp/owlink-dmg-gk.XXXXXX)
    trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG"
    spctl -a -vv -t exec "$MNT/Owlink.app"
    xcrun stapler validate "$MNT/Owlink.app"
fi
# The checks again on the final, stapled image (stapling writes into it).
run Scripts/make-dmg.sh --check "$DMG" "$APP"
echo "DMG ready: $DMG"

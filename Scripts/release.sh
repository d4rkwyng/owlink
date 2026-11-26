#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples "Owlink.app", then zips
# it for distribution. Run on a Mac whose keychain holds a "Developer ID
# Application" certificate. The GitHub release workflow runs this too.
# After Tankard's Scripts/release.sh.
#
#   Scripts/release.sh [--dry-run] [--host-arch] [--skip-notarize] [--skip-launch-check] [--appcast]
#
#   --dry-run        print every command instead of running it (the identity
#                    lookup still runs: it only reads the keychain)
#   --host-arch      build only this Mac's architecture (default: universal)
#   --skip-notarize  sign and verify only
#   --skip-launch-check
#                    don't real-launch the signed app (Scripts/launch-check.sh);
#                    only for a Mac with no logged-in GUI session
#   --appcast        also sign the zip for Sparkle (EdDSA) and add its item
#                    to a local appcast, dist/appcast.xml (see below and
#                    docs/updates.md). Off by default. Uploads nothing.
#
# Settings (environment):
#   CEDRIC_SIGN_ID          signing identity; default: the first
#                           "Developer ID Application:" from
#                           `security find-identity -v -p codesigning`.
#                           "-" signs ad hoc (hardened runtime, no
#                           timestamp) for a local test; it can't be
#                           notarized, so it needs --skip-notarize.
#   CEDRIC_NOTARY_PROFILE   notarytool keychain profile (default: cedric),
#                           made once with `xcrun notarytool store-credentials cedric`
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                           used instead of the profile when all three are set (CI)
#   CEDRIC_VERSION          version string (default: CedricVersion.source in
#                           Sources/CedricCore/Version.swift); must equal it
#   TAG                     the release tag (CI); the built version must be
#                           the tag's without "v" and any "-suffix"
#
# Updates (--appcast only; every one is checked before anything is built,
# and the script refuses to start if one is missing or wrong):
#   CEDRIC_SPARKLE_FEED_URL     the appcast's https:// URL (baked into the
#                               app's Info.plist as SUFeedURL)
#   CEDRIC_SPARKLE_PUBLIC_KEY   the EdDSA public key, base64 (SUPublicEDKey)
#   CEDRIC_SPARKLE_DOWNLOAD_URL the zip's https:// URL once published, with
#                               {version} for the version, e.g.
#                               https://host/v{version}/Owlink-{version}.zip
#   and exactly one source for the EdDSA PRIVATE key, read by Sparkle's
#   sign_update at release time and never copied or stored by this script:
#   CEDRIC_SPARKLE_KEY_FILE     a file outside this repository, readable
#                               by its owner only, or
#   CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT
#                               the login Keychain item's account (Sparkle's
#                               default is "ed25519")
#   CEDRIC_SPARKLE_BIN          folder with Sparkle's sign_update (default:
#                               the pinned package's bin, .build/artifacts)
#   CEDRIC_SPARKLE_APPCAST      a local copy of the published appcast to add
#                               the item to (default: start a new one)
#
# Output: "dist/Owlink.app" (stapled) and dist/Owlink-<version>.zip
# (no spaces in the download's name); when notarizing,
# also dist/notary-result.json (notarytool submit's answer) and
# dist/notary-log.json (Apple's log for that submission, accepted or not).
#
# Nested code: Contents/Frameworks/llama.framework (llama.cpp, the built-in
# AI engine) is signed on its own first, with the same identity, then the
# app; never --deep. The hardened runtime needs no entitlements:
#  - library validation passes because the framework carries our Team ID
#    (checked below: app and framework must have the same one);
#  - ggml's Metal shaders are compiled from source at run time by Metal's
#    own compiler service (MTLCompilerService, a separate process) and run
#    on the GPU, so the app maps no writable+executable memory: no
#    allow-jit or allow-unsigned-executable-memory (checked with a live
#    model load on an ad-hoc hardened-runtime build, docs/architecture.md);
#  - the WKWebView preview runs in WebKit's own XPC processes, which have
#    their own entitlements; outside the App Sandbox the app needs none;
#  - models are downloaded at run time into Application Support, not
#    bundled, and a GGUF is data (mmap'd read-only), not code.
# No App Sandbox: an editor opens arbitrary files by path from the command line.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
UNIVERSAL=1
NOTARIZE=1
LAUNCH_CHECK=1
APPCAST=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --host-arch) UNIVERSAL=0 ;;
        --skip-notarize) NOTARIZE=0 ;;
        --skip-launch-check) LAUNCH_CHECK=0 ;;
        --appcast) APPCAST=1 ;;
        -h|--help) sed -n '2,77p' "$0"; exit 0 ;;
        *) echo "release.sh: unknown option $a" >&2; exit 2 ;;
    esac
done

# Prints the command; runs it unless --dry-run. Secrets are masked.
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

fail() { echo "release.sh: $*" >&2; exit 1; }

# Updates: --appcast refuses to start (even as a dry run) unless the feed,
# the public key, the download URL and one private-key source are all
# given and sane. Nothing here reads or prints the private key.
SPARKLE_SIGN_ARGS=()
SPARKLE_SIGN_UPDATE=""
if [ $APPCAST = 1 ]; then
    feed=${CEDRIC_SPARKLE_FEED_URL:-}
    pub=${CEDRIC_SPARKLE_PUBLIC_KEY:-}
    dl=${CEDRIC_SPARKLE_DOWNLOAD_URL:-}
    keyfile=${CEDRIC_SPARKLE_KEY_FILE:-}
    account=${CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT:-}
    [ -n "$feed" ] || fail "--appcast: CEDRIC_SPARKLE_FEED_URL is not set (the appcast's https:// URL; docs/updates.md)"
    case "$feed" in https://?*) ;; *) fail "--appcast: CEDRIC_SPARKLE_FEED_URL must be an https:// URL" ;; esac
    [ -n "$pub" ] || fail "--appcast: CEDRIC_SPARKLE_PUBLIC_KEY is not set (the EdDSA public key, base64; docs/updates.md)"
    publen=$(printf '%s' "$pub" | base64 -D 2>/dev/null | wc -c | tr -d ' ')
    [ "$publen" = 32 ] || fail "--appcast: CEDRIC_SPARKLE_PUBLIC_KEY is not a base64 EdDSA public key (32 bytes)"
    [ -n "$dl" ] || fail "--appcast: CEDRIC_SPARKLE_DOWNLOAD_URL is not set (where the zip will be published, with {version})"
    case "$dl" in https://?*) ;; *) fail "--appcast: CEDRIC_SPARKLE_DOWNLOAD_URL must be an https:// URL" ;; esac
    case "$dl" in *'{version}'*) ;; *) fail "--appcast: CEDRIC_SPARKLE_DOWNLOAD_URL needs {version} in it" ;; esac
    case "$feed$dl" in *[\<\>\&\"\'[:space:]]*) fail "--appcast: the feed and download URLs may not hold spaces or < > & quotes" ;; esac
    if [ -n "$keyfile" ] && [ -n "$account" ]; then
        fail "--appcast: set CEDRIC_SPARKLE_KEY_FILE or CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT, not both"
    elif [ -n "$keyfile" ]; then
        [ -f "$keyfile" ] || fail "--appcast: CEDRIC_SPARKLE_KEY_FILE is not a file"
        keydir=$(cd "$(dirname "$keyfile")" && pwd -P)
        case "$keydir/" in "$(pwd -P)/"*) fail "--appcast: CEDRIC_SPARKLE_KEY_FILE is inside this repository; keep the private key outside it" ;; esac
        perms=$(stat -f '%Lp' "$keyfile")
        case "$perms" in 400|600) ;; *) fail "--appcast: CEDRIC_SPARKLE_KEY_FILE is mode $perms; make it readable by its owner only (chmod 600)" ;; esac
        SPARKLE_SIGN_ARGS=(--ed-key-file "$keyfile")
    elif [ -n "$account" ]; then
        SPARKLE_SIGN_ARGS=(--account "$account")
    else
        fail "--appcast: no EdDSA private key: set CEDRIC_SPARKLE_KEY_FILE (a file outside the repo) or CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT (docs/updates.md)"
    fi
    [ $NOTARIZE = 1 ] || fail "--appcast: an update must be notarized; drop --skip-notarize"
    if [ -n "${CEDRIC_SPARKLE_BIN:-}" ]; then
        SPARKLE_SIGN_UPDATE="$CEDRIC_SPARKLE_BIN/sign_update"
    else
        SPARKLE_SIGN_UPDATE=$(find .build/artifacts -maxdepth 5 -type f -path '*Sparkle*/bin/sign_update' 2>/dev/null | head -1)
    fi
    [ -n "$SPARKLE_SIGN_UPDATE" ] && [ -x "$SPARKLE_SIGN_UPDATE" ] \
        || fail "--appcast: no Sparkle sign_update (set CEDRIC_SPARKLE_BIN to the bin folder of Sparkle 2.10.1)"
    if [ -n "${CEDRIC_SPARKLE_APPCAST:-}" ]; then
        [ -f "$CEDRIC_SPARKLE_APPCAST" ] || fail "--appcast: CEDRIC_SPARKLE_APPCAST is not a file"
        grep -q '</channel>' "$CEDRIC_SPARKLE_APPCAST" || fail "--appcast: CEDRIC_SPARKLE_APPCAST has no </channel>"
    fi
    # bundle-app.sh bakes these two into Info.plist.
    export CEDRIC_SPARKLE_FEED_URL CEDRIC_SPARKLE_PUBLIC_KEY
    echo "Updates: feed $feed, key from $([ -n "$keyfile" ] && echo "file (outside the repo)" || echo "Keychain account $account"), sign_update $SPARKLE_SIGN_UPDATE"
elif [ -n "${CEDRIC_SPARKLE_FEED_URL:-}" ] || [ -n "${CEDRIC_SPARKLE_PUBLIC_KEY:-}" ]; then
    echo "NOTE: CEDRIC_SPARKLE_FEED_URL / CEDRIC_SPARKLE_PUBLIC_KEY are set but --appcast isn't: the app gets them, no appcast item is made." >&2
fi

APP="dist/Owlink.app"
BIN="$APP/Contents/MacOS/Cedric"
FW="$APP/Contents/Frameworks/llama.framework"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SUBMIT_ZIP=dist/Owlink-notarize.zip

# 0. The version. A release's Info.plist (CEDRIC_VERSION, the tag's in CI)
#    must be the source's.
SOURCE_VERSION=$(sed -n 's/.*static let source = "\([^"]*\)".*/\1/p' Sources/CedricCore/Version.swift)
[ -n "$SOURCE_VERSION" ] || fail "no CedricVersion.source in Sources/CedricCore/Version.swift"
if [ -n "${CEDRIC_VERSION:-}" ] && [ "$CEDRIC_VERSION" != "$SOURCE_VERSION" ]; then
    msg="CEDRIC_VERSION $CEDRIC_VERSION differs from CedricVersion.source $SOURCE_VERSION (bump Sources/CedricCore/Version.swift, or tag the version it says)"
    [ $DRY = 1 ] || fail "$msg"
    echo "(dry run) $msg" >&2
fi
echo "Version: ${CEDRIC_VERSION:-$SOURCE_VERSION}"
ZIP="dist/Owlink-${CEDRIC_VERSION:-$SOURCE_VERSION}.zip"

# 1. Signing identity.
ID=${CEDRIC_SIGN_ID:-}
if [ -z "$ID" ]; then
    echo "+ security find-identity -v -p codesigning"
    ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$ID" ]; then
    msg='no "Developer ID Application:" signing identity in the keychain. Install your Developer ID certificate, or set CEDRIC_SIGN_ID ("-" for an ad-hoc test build with --skip-notarize).'
    [ $DRY = 1 ] || fail "$msg"
    echo "(dry run) $msg Using a placeholder." >&2
    ID="Developer ID Application: EXAMPLE (TEAMID)"
fi
echo "Signing identity: $ID"
if [ "$ID" = "-" ] && [ $NOTARIZE = 1 ]; then
    fail 'an ad-hoc signature (CEDRIC_SIGN_ID=-) cannot be notarized; add --skip-notarize'
fi

# 2. Notary credentials.
NOTARY_ARGS=()
if [ $NOTARIZE = 1 ]; then
    if [ -n "${NOTARY_APPLE_ID:-}" ] || [ -n "${NOTARY_TEAM_ID:-}" ] || [ -n "${NOTARY_PASSWORD:-}" ]; then
        [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] \
            || fail "set all three of NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD, or none (to use a keychain profile)"
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
    else
        NOTARY_ARGS=(--keychain-profile "${CEDRIC_NOTARY_PROFILE:-cedric}")
    fi
fi

# 3. Build and assemble (unsigned), sharing bundle-app.sh.
# --release: no dev/check switches in what ships (DevEnvironment.swift).
BUNDLE_ARGS=(--no-sign --release)
if [ $UNIVERSAL = 1 ]; then
    BUNDLE_ARGS+=(--universal)
else
    echo "NOTE: --host-arch: building $(uname -m) only; this release will not run on the other architecture." >&2
fi
run Scripts/bundle-app.sh "${BUNDLE_ARGS[@]}"
if [ $DRY = 0 ]; then
    [ -d "$FW" ] || fail "missing $FW (bundle-app.sh copies it)"
    [ -d "$SPARKLE_FW" ] || fail "missing $SPARKLE_FW (bundle-app.sh --release copies it)"
    if [ $UNIVERSAL = 1 ]; then
        for b in "$BIN" "$FW/Versions/Current/llama"; do
            archs=$(lipo -archs "$b")
            case "$archs" in
                *x86_64*arm64*|*arm64*x86_64*) ;;
                *) fail "expected a universal binary at $b, got: $archs" ;;
            esac
        done
    fi
fi
# 3b. The built artifact's version, before anything is signed: its
#     Info.plist must equal CedricVersion.source, CEDRIC_VERSION if set,
#     and in CI the tag's version ($TAG without "v" and its suffix).
if [ $DRY = 0 ]; then
    BUILT=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null) \
        || fail "can't read CFBundleShortVersionString from $APP/Contents/Info.plist"
    WHY=()
    [ "$BUILT" = "$SOURCE_VERSION" ] || WHY+=("CedricVersion.source is $SOURCE_VERSION")
    if [ -n "${CEDRIC_VERSION:-}" ] && [ "$BUILT" != "$CEDRIC_VERSION" ]; then WHY+=("CEDRIC_VERSION is $CEDRIC_VERSION"); fi
    if [ -n "${TAG:-}" ]; then
        TAG_VERSION=${TAG#v}; TAG_VERSION=${TAG_VERSION%%-*}
        [ "$BUILT" = "$TAG_VERSION" ] || WHY+=("tag $TAG is $TAG_VERSION")
    fi
    [ ${#WHY[@]} = 0 ] || fail "$APP is version $BUILT, but $(IFS=';'; echo "${WHY[*]}" | sed 's/;/, /g')"
    echo "Built version: $BUILT (= CedricVersion.source${CEDRIC_VERSION:+ = CEDRIC_VERSION}${TAG:+ = tag $TAG})"
else
    echo "+ plutil -extract CFBundleShortVersionString raw $APP/Contents/Info.plist  # must equal $SOURCE_VERSION${TAG:+ and tag $TAG}"
fi

# 4. Sign inside out: nested code first (llama.framework, and any other
#    framework/dylib/XPC a later version adds), then the app. No --deep:
#    each piece gets its own signature with the hardened runtime and a
#    secure timestamp (notarization requires both). Sparkle.framework is
#    signed in its own documented order by Scripts/sign-sparkle.sh (XPC
#    services, Autoupdate, Updater.app, the framework; Downloader.xpc
#    keeps its entitlements), so the generic pass leaves it alone.
APP_SIGN_EXTRA=()
if [ "$ID" = "-" ]; then
    SIGN=(codesign --force --options runtime --timestamp=none -s -)
    # Ad hoc only: an ad-hoc signature has no Team ID, so the hardened
    # runtime's library validation refuses llama.framework ("mapping process
    # and mapped file (non-platform) have different Team IDs") and the app
    # can't start. A local test build therefore turns library validation
    # off. A Developer ID build never gets this (checked in 4a).
    ADHOC_ENTS=dist/adhoc-test.entitlements
    if [ $DRY = 0 ]; then
        mkdir -p dist
        cat > "$ADHOC_ENTS" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
ENTS
    fi
    APP_SIGN_EXTRA=(--entitlements "$ADHOC_ENTS")
    echo "NOTE: ad-hoc test build: the app gets com.apple.security.cs.disable-library-validation (no Team ID to validate against); a Developer ID release gets no entitlements." >&2
else
    SIGN=(codesign --force --options runtime --timestamp -s "$ID")
fi
if [ $DRY = 0 ]; then
    nested=0
    while IFS= read -r -d '' f; do
        run "${SIGN[@]}" "$f"
        nested=$((nested + 1))
    done < <(find "$APP/Contents" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) \
                 -not -path "$SPARKLE_FW" -not -path "$SPARKLE_FW/*" -print0)
    [ $nested -ge 1 ] || fail "found no nested code to sign; llama.framework should be there"
    echo "+ Scripts/sign-sparkle.sh $SPARKLE_FW $(printf '%q ' "${SIGN[@]}")"
    Scripts/sign-sparkle.sh "$SPARKLE_FW" "${SIGN[@]}"
else
    run "${SIGN[@]}" "$FW"
    Scripts/sign-sparkle.sh --dry-run "$SPARKLE_FW" "${SIGN[@]}"
fi
run "${SIGN[@]}" ${APP_SIGN_EXTRA[@]+"${APP_SIGN_EXTRA[@]}"} "$APP"
run codesign --verify --strict --deep --verbose=2 "$APP"
run codesign --verify --strict --verbose=2 "$FW"
run codesign --verify --strict --deep --verbose=2 "$SPARKLE_FW"

# 4a. What library validation will see at launch: the app and the
#     framework signed by the same team (both "not set" when ad hoc), both
#     with the hardened runtime, and no entitlements on either (ad hoc:
#     only the app's disable-library-validation, see 4).
sig_field() { codesign -dvv "$1" 2>&1 | sed -n "s/^$2=//p" | head -1; }
if [ $DRY = 0 ]; then
    APP_TEAM=$(sig_field "$APP" TeamIdentifier)
    FW_TEAM=$(sig_field "$FW" TeamIdentifier)
    [ "$APP_TEAM" = "$FW_TEAM" ] || fail "Team IDs differ: app $APP_TEAM, llama.framework $FW_TEAM (library validation would refuse to load it)"
    for p in "$SPARKLE_FW" "$SPARKLE_FW/Versions/B/Autoupdate" "$SPARKLE_FW/Versions/B/Updater.app" \
             "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"; do
        t=$(sig_field "$p" TeamIdentifier)
        [ "$t" = "$APP_TEAM" ] || fail "Team IDs differ: app $APP_TEAM, $p $t"
        info=$(codesign -dv "$p" 2>&1 || true)
        grep -q '^CodeDirectory .*flags=.*runtime' <<<"$info" || fail "$p is not signed with the hardened runtime"
    done
    for p in "$APP" "$FW"; do
        # Captured first: `grep -q` on a pipe would SIGPIPE codesign under pipefail.
        info=$(codesign -dv "$p" 2>&1 || true)
        grep -q '^CodeDirectory .*flags=.*runtime' <<<"$info" || fail "$p is not signed with the hardened runtime"
        ents=$(codesign -d --entitlements - --xml "$p" 2>/dev/null | tr -d '\0' || true)
        keys=$(printf '%s' "$ents" | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g' | tr '\n' ' ' || true)
        allowed=""
        [ "$ID" = "-" ] && [ "$p" = "$APP" ] && allowed="com.apple.security.cs.disable-library-validation "
        [ "$keys" = "$allowed" ] || fail "$p has entitlements [${keys% }], expected [${allowed% }]"
    done
    echo "Signatures: app, llama.framework and Sparkle.framework (with its helpers), Team ID $APP_TEAM, hardened runtime, entitlements: $([ "$ID" = "-" ] && echo "ad-hoc test only: disable-library-validation" || echo none)"
fi

# 4b. Launch the signed app for real (no dev switches) and fail the release
#     if it crashes or quits. Tankard 0.3.0 shipped a launch crash only the
#     signed release build showed, and only on a real launch.
if [ $LAUNCH_CHECK = 1 ]; then
    run Scripts/launch-check.sh --release "$APP" --runs 5 --seconds 10
else
    echo "NOTE: --skip-launch-check: the signed app was not launched. Run Scripts/launch-check.sh $APP before publishing." >&2
fi

if [ $NOTARIZE = 0 ]; then
    run rm -f "$ZIP"
    run ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Signed but not notarized: $ZIP"
    exit 0
fi

# 5. Notarize, staple, verify with Gatekeeper.
run rm -f "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
RESULT=dist/notary-result.json
# Apple's log for the submission, fetched after every submission (Accepted
# or not) and printed, so CI keeps it (release.yml uploads both files as a
# workflow artifact, also when this step fails). It holds the submission
# id, status, archive name, upload date, the zip's sha256, the signed
# binaries' cdhashes and the issues list; no Apple ID, password or
# certificate.
NOTARY_LOG=dist/notary-log.json
notary_log() { # submission id
    local i
    run rm -f "$NOTARY_LOG"
    # The log can lag the status by a few seconds; three tries.
    for i in 1 2 3; do
        if run xcrun notarytool log "${NOTARY_ARGS[@]}" "$1" "$NOTARY_LOG"; then
            [ $DRY = 1 ] || { echo "--- $NOTARY_LOG"; cat "$NOTARY_LOG"; echo; echo "---"; }
            return 0
        fi
        [ $i = 3 ] || sleep 10
    done
    echo "release.sh: could not fetch the notary log for $1" >&2
    return 1
}
if [ $DRY = 1 ]; then
    run xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json
    notary_log "<submission-id>"
else
    run rm -f "$RESULT" "$NOTARY_LOG"
    echo "+ xcrun notarytool submit $SUBMIT_ZIP ${NOTARY_ARGS[0]} … --wait --output-format json"
    # Not under `set -e`: an Invalid submission must still get its log.
    SUBMIT_RC=0
    xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json | tee "$RESULT" || SUBMIT_RC=$?
    echo
    STATUS=$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)
    SUB_ID=$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)
    LOG_OK=0
    if [ -n "$SUB_ID" ]; then
        notary_log "$SUB_ID" && LOG_OK=1
    else
        echo "release.sh: no submission id in $RESULT (notarytool exit $SUBMIT_RC): nothing was submitted, no log" >&2
    fi
    if [ "$STATUS" != "Accepted" ]; then
        fail "notarization status: $STATUS (notarytool exit $SUBMIT_RC). Apple's log: $([ $LOG_OK = 1 ] && echo "$NOTARY_LOG, printed above" || echo "xcrun notarytool log ${SUB_ID:-<id>} ${NOTARY_ARGS[0]} …")"
    fi
    # Accepted with no log: the release goes on (the ticket is what ships),
    # but say so; the workflow artifact will lack notary-log.json.
    [ $LOG_OK = 1 ] || echo "WARNING: notarization Accepted, but Apple's log could not be fetched" >&2
fi
run xcrun stapler staple "$APP"
run xcrun stapler validate "$APP"
run spctl -a -vv -t exec "$APP"

# 6. The distribution zip (stapled app).
run rm -f "$ZIP" "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release ready: $ZIP"
[ $APPCAST = 1 ] || exit 0

# 7. The update (--appcast): Sparkle's EdDSA signature for the zip, checked
#    against the public key the app ships, an appcast item for it in a
#    local dist/appcast.xml (a copy of CEDRIC_SPARKLE_APPCAST, or a new
#    feed), the feed signed too (SURequireSignedFeed), and a list of what
#    to upload. This script uploads nothing.
VERSION=${CEDRIC_VERSION:-$SOURCE_VERSION}
APPCAST_OUT=dist/appcast.xml
ENCLOSURE=${CEDRIC_SPARKLE_DOWNLOAD_URL//\{version\}/$VERSION}
if [ $DRY = 1 ]; then
    echo "+ $(printf '%q ' "$SPARKLE_SIGN_UPDATE" "${SPARKLE_SIGN_ARGS[@]}" "$ZIP")"
    echo "+ swift Scripts/ed-verify.swift <CEDRIC_SPARKLE_PUBLIC_KEY> <signature> $ZIP"
    echo "+ (add the $VERSION item, enclosure $ENCLOSURE, to $APPCAST_OUT)"
    echo "+ $(printf '%q ' "$SPARKLE_SIGN_UPDATE" "${SPARKLE_SIGN_ARGS[@]}" "$APPCAST_OUT")"
    echo "+ $(printf '%q ' "$SPARKLE_SIGN_UPDATE" --verify "${SPARKLE_SIGN_ARGS[@]}" "$APPCAST_OUT")"
    exit 0
fi
# The app as built must carry this feed and key.
[ "$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist")" = "$CEDRIC_SPARKLE_FEED_URL" ] || fail "$APP's SUFeedURL isn't CEDRIC_SPARKLE_FEED_URL"
[ "$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")" = "$CEDRIC_SPARKLE_PUBLIC_KEY" ] || fail "$APP's SUPublicEDKey isn't CEDRIC_SPARKLE_PUBLIC_KEY"
echo "+ $(printf '%q ' "$SPARKLE_SIGN_UPDATE" "${SPARKLE_SIGN_ARGS[@]}" "$ZIP")"
ATTRS=$("$SPARKLE_SIGN_UPDATE" "${SPARKLE_SIGN_ARGS[@]}" "$ZIP") || fail "sign_update could not sign $ZIP"
ED_SIG=$(sed -n 's/.*sparkle:edSignature="\([A-Za-z0-9+/=]*\)".*/\1/p' <<<"$ATTRS")
ED_LEN=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$ATTRS")
[ -n "$ED_SIG" ] && [ "$ED_LEN" = "$(stat -f '%z' "$ZIP")" ] || fail "sign_update's output isn't a signature and length for $ZIP: $ATTRS"
swift Scripts/ed-verify.swift "$CEDRIC_SPARKLE_PUBLIC_KEY" "$ED_SIG" "$ZIP" \
    || fail "the private key doesn't match CEDRIC_SPARKLE_PUBLIC_KEY: installed copies would refuse this update"
if [ -n "${CEDRIC_SPARKLE_APPCAST:-}" ]; then
    [ "$(cd "$(dirname "$CEDRIC_SPARKLE_APPCAST")" && pwd -P)/$(basename "$CEDRIC_SPARKLE_APPCAST")" = "$(pwd -P)/$APPCAST_OUT" ] \
        || cp "$CEDRIC_SPARKLE_APPCAST" "$APPCAST_OUT"
else
    cat > "$APPCAST_OUT" <<'FEED'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Owlink</title>
    </channel>
</rss>
FEED
fi
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_OUT" \
    && fail "$APPCAST_OUT already has an item for $VERSION"
ITEM=$(mktemp)
trap 'rm -f "$ITEM"' EXIT
cat > "$ITEM" <<ITEMXML
        <item>
            <title>Version $VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="$ENCLOSURE" length="$ED_LEN" type="application/octet-stream" sparkle:edSignature="$ED_SIG"/>
        </item>
ITEMXML
# The new item goes before the first existing one (else at the end of the
# channel). Sparkle offers the highest version, whatever the order.
awk -v item="$ITEM" '
    !done && (/<item[ >]/ || /<\/channel>/) { while ((getline l < item) > 0) print l; done = 1 }
    { print }
' "$APPCAST_OUT" > "$APPCAST_OUT.new" && mv "$APPCAST_OUT.new" "$APPCAST_OUT"
xmllint --noout "$APPCAST_OUT" || fail "$APPCAST_OUT is not well-formed XML"
echo "+ $(printf '%q ' "$SPARKLE_SIGN_UPDATE" "${SPARKLE_SIGN_ARGS[@]}" "$APPCAST_OUT")"
"$SPARKLE_SIGN_UPDATE" "${SPARKLE_SIGN_ARGS[@]}" "$APPCAST_OUT" || fail "sign_update could not sign $APPCAST_OUT"
"$SPARKLE_SIGN_UPDATE" --verify "${SPARKLE_SIGN_ARGS[@]}" "$APPCAST_OUT" || fail "$APPCAST_OUT's signature doesn't verify"
echo
echo "Nothing was uploaded. To publish this update, by hand:"
echo "  1. $ZIP  ->  $ENCLOSURE"
echo "  2. $APPCAST_OUT  ->  $CEDRIC_SPARKLE_FEED_URL   (after 1; replaces the published feed)"
echo "  sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)  $ZIP"

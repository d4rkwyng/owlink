#!/bin/bash
# Checks the update plumbing (Sparkle 2, docs/updates.md) without a key,
# a feed or the network:
#  - release.sh --appcast refuses to start, before it builds or reads the
#    keychain, whenever the feed URL, the public key, the download URL or a
#    private-key source is missing or wrong (always also --dry-run, so even
#    a broken guard couldn't sign or upload anything; the script has no
#    upload code at all);
#  - bundle-app.sh refuses a non-HTTPS feed;
#  - sign-sparkle.sh signs in Sparkle's order and refuses --deep;
#  - ed-verify.swift refuses malformed input;
#  - with an APP: its Info.plist has the empty placeholders, a required
#    signed feed and automatic checks off.
# No key of any kind is generated or read: the "key file" below is an
# empty temp file, refused before anything would read it.
#
#   Scripts/updates-check.sh [APP]
set -uo pipefail
cd "$(dirname "$0")/.."
APP=${1:-}
pass=0; failed=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; failed=$((failed + 1)); }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FEED=https://updates.example.invalid/owlink/appcast.xml
DL='https://downloads.example.invalid/v{version}/Owlink-{version}.zip'
# 32 bytes of ASCII, base64: the shape of a public key, not a key.
PUB=$(printf 'owlink-test-only-not-a-real-key!' | base64)

# release.sh --appcast --dry-run with only the given CEDRIC_SPARKLE_*
# variables; must exit non-zero, print `want`, and never reach the build.
refuses() { # name want [VAR=value…] [-- extra release.sh args]
    local name=$1 want=$2; shift 2
    local vars=() extra=()
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then shift; extra=("$@"); break; fi
        vars+=("$1"); shift
    done
    local out rc=0
    out=$(env -u CEDRIC_SPARKLE_FEED_URL -u CEDRIC_SPARKLE_PUBLIC_KEY -u CEDRIC_SPARKLE_DOWNLOAD_URL \
              -u CEDRIC_SPARKLE_KEY_FILE -u CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT -u CEDRIC_SPARKLE_BIN \
              -u CEDRIC_SPARKLE_APPCAST -u CEDRIC_SIGN_ID ${vars[@]+"${vars[@]}"} \
              Scripts/release.sh --dry-run --appcast ${extra[@]+"${extra[@]}"} 2>&1) || rc=$?
    if [ $rc = 0 ]; then bad "release.sh refuses: $name (it ran: exit 0)"; return; fi
    if ! grep -qF -- "$want" <<<"$out"; then bad "release.sh refuses: $name (wanted \"$want\", got: $(head -3 <<<"$out"))"; return; fi
    if grep -qE '^\+ (Scripts/bundle-app.sh|security|codesign|xcrun)' <<<"$out"; then bad "release.sh refuses: $name, but only after starting the release"; return; fi
    ok "release.sh refuses: $name"
}

refuses "no feed URL" "CEDRIC_SPARKLE_FEED_URL is not set"
refuses "no feed URL, even with everything else" "CEDRIC_SPARKLE_FEED_URL is not set" \
    CEDRIC_SPARKLE_PUBLIC_KEY="$PUB" CEDRIC_SPARKLE_DOWNLOAD_URL="$DL" CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519
refuses "an http:// feed" "must be an https:// URL" CEDRIC_SPARKLE_FEED_URL=http://updates.example.invalid/appcast.xml
refuses "no public key" "CEDRIC_SPARKLE_PUBLIC_KEY is not set" CEDRIC_SPARKLE_FEED_URL=$FEED
refuses "a public key that isn't 32 bytes" "not a base64 EdDSA public key" \
    CEDRIC_SPARKLE_FEED_URL=$FEED CEDRIC_SPARKLE_PUBLIC_KEY=PUBLIC_KEY_HERE
refuses "no download URL" "CEDRIC_SPARKLE_DOWNLOAD_URL is not set" CEDRIC_SPARKLE_FEED_URL=$FEED CEDRIC_SPARKLE_PUBLIC_KEY="$PUB"
refuses "an http:// download URL" "CEDRIC_SPARKLE_DOWNLOAD_URL must be an https:// URL" \
    CEDRIC_SPARKLE_FEED_URL=$FEED CEDRIC_SPARKLE_PUBLIC_KEY="$PUB" CEDRIC_SPARKLE_DOWNLOAD_URL=http://downloads.example.invalid/x.zip
refuses "a download URL without {version}" "needs {version}" \
    CEDRIC_SPARKLE_FEED_URL=$FEED CEDRIC_SPARKLE_PUBLIC_KEY="$PUB" CEDRIC_SPARKLE_DOWNLOAD_URL=https://downloads.example.invalid/Owlink.zip
refuses "a feed URL with a quote" "may not hold spaces" \
    CEDRIC_SPARKLE_FEED_URL='https://updates.example.invalid/a"b.xml' CEDRIC_SPARKLE_PUBLIC_KEY="$PUB" CEDRIC_SPARKLE_DOWNLOAD_URL="$DL"
SET=(CEDRIC_SPARKLE_FEED_URL=$FEED CEDRIC_SPARKLE_PUBLIC_KEY="$PUB" CEDRIC_SPARKLE_DOWNLOAD_URL="$DL")
refuses "no private key source" "no EdDSA private key" "${SET[@]}"
refuses "two private key sources" "not both" "${SET[@]}" CEDRIC_SPARKLE_KEY_FILE="$W/none" CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519
refuses "a key file that doesn't exist" "CEDRIC_SPARKLE_KEY_FILE is not a file" "${SET[@]}" CEDRIC_SPARKLE_KEY_FILE="$W/none"
# An ordinary file of the repository stands in for "a key kept in the repo".
refuses "a key file inside the repository" "inside this repository" "${SET[@]}" CEDRIC_SPARKLE_KEY_FILE="$PWD/README.md"
: > "$W/empty-not-a-key"
chmod 644 "$W/empty-not-a-key"
refuses "a key file others can read" "readable by its owner only" "${SET[@]}" CEDRIC_SPARKLE_KEY_FILE="$W/empty-not-a-key"
chmod 600 "$W/empty-not-a-key"
refuses "an update that isn't notarized" "must be notarized" "${SET[@]}" CEDRIC_SPARKLE_KEY_FILE="$W/empty-not-a-key" -- --skip-notarize
refuses "an update that isn't notarized (Keychain key)" "must be notarized" "${SET[@]}" CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519 -- --skip-notarize
# A host-arch build is one architecture, but an appcast item has none, so
# every Mac would be offered it. CEDRIC_SIGN_ID=- keeps a broken guard from
# even looking up an identity.
refuses "an update that isn't universal (--host-arch)" "must be universal" "${SET[@]}" CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519 CEDRIC_SIGN_ID=- -- --host-arch
refuses "no sign_update" "no Sparkle sign_update" "${SET[@]}" CEDRIC_SPARKLE_KEY_FILE="$W/empty-not-a-key" CEDRIC_SPARKLE_BIN="$W/no-bin"
# Past the sign_update lookup only when the pinned package's tools are in
# .build (after `swift build`); sign_update is found, not run.
if find .build/artifacts -maxdepth 5 -type f -path '*Sparkle*/bin/sign_update' 2>/dev/null | grep -q .; then
    refuses "an appcast copy that isn't there" "CEDRIC_SPARKLE_APPCAST is not a file" "${SET[@]}" CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519 \
        CEDRIC_SPARKLE_APPCAST="$W/none.xml"
else
    echo "note: no Sparkle tools in .build/artifacts (run swift build); appcast-copy refusal not checked"
fi

# Without --appcast the release flow is unchanged: the dry run starts.
out=$(env -u CEDRIC_SPARKLE_FEED_URL -u CEDRIC_SPARKLE_PUBLIC_KEY CEDRIC_SIGN_ID=- Scripts/release.sh --dry-run --skip-notarize --skip-launch-check 2>&1); rc=$?
if [ $rc = 0 ] && grep -q '^+ Scripts/bundle-app.sh' <<<"$out" && grep -q 'Sparkle.framework/Versions/B/Autoupdate$' <<<"$out" && ! grep -q 'sign_update' <<<"$out"; then
    ok "release.sh without --appcast: dry run as before, Sparkle signed in its order, no sign_update"
else
    bad "release.sh without --appcast (exit $rc): $(tail -3 <<<"$out")"
fi
grep -nE 'curl|scp |rsync|gh release|aws |gsutil|sftp|ftp ' Scripts/release.sh >/dev/null \
    && bad "release.sh has upload code" || ok "release.sh has no upload code (curl, scp, rsync, gh release, aws, gsutil, sftp)"

# bundle-app.sh: a non-HTTPS feed is refused before anything is built.
out=$(CEDRIC_SPARKLE_FEED_URL=http://updates.example.invalid/appcast.xml Scripts/bundle-app.sh --out "$W/out" 2>&1); rc=$?
if [ $rc != 0 ] && grep -q "must be an https:// URL" <<<"$out" && ! grep -q '==> swift build' <<<"$out"; then
    ok "bundle-app.sh refuses an http:// feed before building"
else
    bad "bundle-app.sh with an http:// feed (exit $rc): $(tail -2 <<<"$out")"
fi

# sign-sparkle.sh: Sparkle's order, Downloader keeps its entitlements, no --deep.
order=$(Scripts/sign-sparkle.sh --dry-run X.framework codesign -s - --force 2>&1 | sed 's/^+ codesign -s - --force //')
want="X.framework/Versions/B/XPCServices/Installer.xpc
--preserve-metadata=entitlements X.framework/Versions/B/XPCServices/Downloader.xpc
X.framework/Versions/B/Autoupdate
X.framework/Versions/B/Updater.app
X.framework"
[ "$order" = "$want" ] && ok "sign-sparkle.sh signs XPC services, Autoupdate, Updater.app, then the framework" || bad "sign-sparkle.sh order: $order"
Scripts/sign-sparkle.sh --dry-run X.framework codesign --deep -s - >/dev/null 2>&1 && bad "sign-sparkle.sh took --deep" || ok "sign-sparkle.sh refuses --deep"

# ed-verify.swift: malformed input is refused (exit 2); no key is involved.
rc=0; swift Scripts/ed-verify.swift PUBLIC_KEY_HERE AAAA README.md >/dev/null 2>&1 || rc=$?
[ $rc = 2 ] && ok "ed-verify.swift refuses a key that isn't 32 bytes" || bad "ed-verify.swift with a bad key: exit $rc"
rc=0; swift Scripts/ed-verify.swift "$PUB" AAAA README.md >/dev/null 2>&1 || rc=$?
[ $rc = 2 ] && ok "ed-verify.swift refuses a signature that isn't 64 bytes" || bad "ed-verify.swift with a bad signature: exit $rc"

if [ -n "$APP" ]; then
    P="$APP/Contents/Info.plist"
    v() { plutil -extract "$1" raw "$P" 2>/dev/null; }
    [ "$(v SUFeedURL)" = "" ] && plutil -extract SUFeedURL raw "$P" >/dev/null 2>&1 \
        && ok "$APP: SUFeedURL is an empty placeholder" || bad "$APP: SUFeedURL is '$(v SUFeedURL)'"
    [ "$(v SUPublicEDKey)" = "" ] && plutil -extract SUPublicEDKey raw "$P" >/dev/null 2>&1 \
        && ok "$APP: SUPublicEDKey is an empty placeholder" || bad "$APP: SUPublicEDKey is '$(v SUPublicEDKey)'"
    [ "$(v SURequireSignedFeed)" = true ] && ok "$APP: SURequireSignedFeed" || bad "$APP: SURequireSignedFeed is '$(v SURequireSignedFeed)'"
    [ "$(v SUVerifyUpdateBeforeExtraction)" = true ] && ok "$APP: SUVerifyUpdateBeforeExtraction" || bad "$APP: SUVerifyUpdateBeforeExtraction"
    [ "$(v SUEnableAutomaticChecks)" = false ] && ok "$APP: automatic checks off by default" || bad "$APP: SUEnableAutomaticChecks is '$(v SUEnableAutomaticChecks)'"
    [ "$(v SUAutomaticallyUpdate)" = false ] && ok "$APP: no silent installs" || bad "$APP: SUAutomaticallyUpdate"
    # Nothing of Sparkle's is linked: the app loads it only when set up.
    otool -L "$APP/Contents/MacOS/Cedric" | grep -q Sparkle && bad "$APP links Sparkle at launch" || ok "$APP doesn't link Sparkle (dlopen only when set up)"
fi

echo "updates-check: $pass passed, $failed failed"
[ $failed = 0 ]

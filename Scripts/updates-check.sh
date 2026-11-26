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
#  - appcast-item.sh (the feed step) keeps the last signed feed when
#    signing or verifying fails, with a stub sign_update; finds duplicates
#    by XML value and adds the item inside the channel whatever the layout;
#  - with an APP: its Info.plist has the empty placeholders, a required
#    signed feed and automatic checks off, and bundle-app.sh's ad-hoc
#    signing (sign-adhoc.sh) keeps Downloader.xpc's entitlements on a temp
#    copy with Sparkle.framework added.
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

# appcast-item.sh (release.sh --appcast's feed step) with a stub
# sign_update, not Sparkle's and no key: the stub appends a fake signature
# comment, or fails when told to. The last signed feed must stay byte for
# byte as it was whenever signing or verifying fails, and a retry must work.
mkdir -p "$W/stub" "$W/dist"
cat > "$W/stub/sign_update" <<'STUB'
#!/bin/bash
# Test stub for Sparkle's sign_update: no key, no crypto.
verify=0; f=""
for a in "$@"; do [ "$a" = --verify ] && verify=1; f=$a; done
echo "$verify $f" >> "$STUB_LOG"
if [ $verify = 1 ]; then
    [ "${STUB_FAIL:-}" = verify ] && { echo "stub: verify fails" >&2; exit 1; }
    grep -q '^edSignature: STUB$' "$f"
else
    [ "${STUB_FAIL:-}" = sign ] && { echo "stub: sign fails" >&2; exit 1; }
    # Drop an earlier signature block, then append a new one.
    awk '/^<!-- sparkle-signatures:/ { skip = 1 } !skip { print } skip && /^-->/ { skip = 0 }' "$f" > "$f.stub" && cat "$f.stub" > "$f" && rm "$f.stub"
    printf '<!-- sparkle-signatures:\nedSignature: STUB\n-->\n' >> "$f"
    [ "${STUB_FAIL:-}" = sign-partial ] && { printf '<garbage' >> "$f"; echo "stub: sign fails half way" >&2; exit 1; }
    exit 0
fi
STUB
chmod +x "$W/stub/sign_update"
FEEDOUT="$W/dist/appcast.xml"
SIG64=$(printf '%064d' 0 | base64 | tr -d '\n')
item() { # version [--from FEED] -> exit code; output in $W/item.out
    local v=$1; shift
    : > "$W/stub.log"
    STUB_LOG="$W/stub.log" Scripts/appcast-item.sh --out "$FEEDOUT" --sign-update "$W/stub/sign_update" \
        --version "$v" --url "https://downloads.example.invalid/v$v/Owlink-$v.zip" --length 1234 --signature "$SIG64" \
        "$@" -- --account owlink-test-only > "$W/item.out" 2>&1
}
leftovers() { ls -A "$W/dist" | grep -v '^appcast\.xml$' | tr '\n' ' '; }
# How many direct /rss/channel/item elements carry version $1 in a Sparkle
# field (found by namespace URI), in $2 or the feed. Python's ElementTree,
# not the scripts' xmllint XPath, so the check doesn't share their logic.
items() {
    /usr/bin/python3 -I - "${2:-$FEEDOUT}" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(sys.argv[1]).getroot()
n = 0
if root.tag == "rss":
    for item in root.findall("channel/item"):
        vals = [(e.text or "").strip() for e in item if e.tag in (NS + "version", NS + "shortVersionString")]
        for enc in item.findall("enclosure"):
            vals += [enc.get(NS + "version", "").strip(), enc.get(NS + "shortVersionString", "").strip()]
        n += sys.argv[2] in vals
print(n)
PY
}
if item 1.0.0 && xmllint --noout "$FEEDOUT" && [ "$(items 1.0.0)" = 1 ] && grep -q '^edSignature: STUB$' "$FEEDOUT" && [ -z "$(leftovers)" ]; then
    ok "appcast-item.sh starts a new feed, signed and verified"
else
    bad "appcast-item.sh new feed: $(tail -2 "$W/item.out") leftovers: $(leftovers)"
fi
# sign_update saw only a temp .xml beside the feed, never the feed itself.
if [ "$(wc -l < "$W/stub.log" | tr -d ' ')" = 2 ] && ! awk '{ print $2 }' "$W/stub.log" | grep -vqE "^$W/dist/\.appcast-new\.[A-Za-z0-9]+\.xml$"; then
    ok "appcast-item.sh signs and verifies a temp .xml beside the feed, not the feed"
else
    bad "appcast-item.sh signed: $(tr '\n' ' ' < "$W/stub.log")"
fi
cp "$FEEDOUT" "$W/last-signed.xml"
for how in sign sign-partial verify; do
    rc=0; STUB_FAIL=$how item 1.1.0 --from "$FEEDOUT" || rc=$?
    if [ $rc != 0 ] && cmp -s "$FEEDOUT" "$W/last-signed.xml" && [ -z "$(leftovers)" ]; then
        ok "appcast-item.sh: when $how fails, the last signed feed is byte-identical and no temp file is left"
    else
        bad "appcast-item.sh with $how failing (exit $rc): feed $(cmp -s "$FEEDOUT" "$W/last-signed.xml" && echo unchanged || echo CHANGED), leftovers: $(leftovers)"
    fi
done
if item 1.1.0 --from "$FEEDOUT" && xmllint --noout "$FEEDOUT" && [ "$(items 1.1.0)" = 1 ] && [ "$(items 1.0.0)" = 1 ] \
    && [ "$(grep -c '^edSignature: STUB$' "$FEEDOUT")" = 1 ] && [ -z "$(leftovers)" ]; then
    ok "appcast-item.sh: the retry after a failure isn't refused as a duplicate and adds the item"
else
    bad "appcast-item.sh retry: $(tail -2 "$W/item.out")"
fi
cp "$FEEDOUT" "$W/last-signed.xml"
rc=0; item 1.1.0 --from "$FEEDOUT" || rc=$?
if [ $rc != 0 ] && grep -q 'already has an item for 1.1.0' "$W/item.out" && cmp -s "$FEEDOUT" "$W/last-signed.xml" && [ ! -s "$W/stub.log" ]; then
    ok "appcast-item.sh refuses a version the feed has, before signing, feed unchanged"
else
    bad "appcast-item.sh duplicate (exit $rc): $(tail -2 "$W/item.out")"
fi
printf '<rss><channel><item></channel>\n' > "$W/broken.xml"
rc=0; item 1.2.0 --from "$W/broken.xml" 2>/dev/null || rc=$?
if [ $rc != 0 ] && cmp -s "$FEEDOUT" "$W/last-signed.xml" && [ ! -s "$W/stub.log" ] && [ -z "$(leftovers)" ]; then
    ok "appcast-item.sh refuses malformed XML before signing, feed unchanged"
else
    bad "appcast-item.sh with malformed XML (exit $rc): $(tail -2 "$W/item.out")"
fi
# Duplicates by XML value. A dashed 1-2-3 isn't 1.2.3 (a regex would say
# it is), so 1.2.3 is added beside it.
cat > "$W/dashes.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Owlink</title>
        <item>
            <sparkle:version>1-2-3</sparkle:version>
            <sparkle:shortVersionString>1-2-3</sparkle:shortVersionString>
        </item>
    </channel>
</rss>
XML
if item 1.2.3 --from "$W/dashes.xml" && [ "$(items 1.2.3)" = 1 ] && [ "$(items 1-2-3)" = 1 ] && [ -z "$(leftovers)" ]; then
    ok "appcast-item.sh: 1.2.3 isn't taken for a duplicate of 1-2-3"
else
    bad "appcast-item.sh 1.2.3 beside 1-2-3: $(tail -2 "$W/item.out")"
fi
# A real duplicate under another prefix for Sparkle's namespace, or with
# the value on its own line, is refused before signing.
cat > "$W/dup-prefix.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sp="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel><title>Owlink</title><item><sp:version>1.3.0</sp:version><sp:shortVersionString>1.3.0</sp:shortVersionString></item></channel>
</rss>
XML
cat > "$W/dup-lines.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Owlink</title>
        <item>
            <sparkle:shortVersionString>
                1.3.0
            </sparkle:shortVersionString>
        </item>
    </channel>
</rss>
XML
cp "$FEEDOUT" "$W/last-signed.xml"
for d in dup-prefix dup-lines; do
    rc=0; item 1.3.0 --from "$W/$d.xml" || rc=$?
    if [ $rc != 0 ] && grep -q 'already has an item for 1.3.0' "$W/item.out" && cmp -s "$FEEDOUT" "$W/last-signed.xml" \
        && [ ! -s "$W/stub.log" ] && [ -z "$(leftovers)" ]; then
        ok "appcast-item.sh refuses a duplicate written as in $d.xml, before signing, feed unchanged"
    else
        bad "appcast-item.sh duplicate in $d.xml (exit $rc): $(tail -2 "$W/item.out")"
    fi
done
# The item lands as a direct child of channel whatever the layout: with
# <channel><item> on one line under <rss> (a line-based insert put it
# under <rss>, still well-formed), and with the whole feed on one line.
NSDECL='xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'
OLDITEM='<item><title>Version 0.9.0</title><sparkle:version>0.9.0</sparkle:version><sparkle:shortVersionString>0.9.0</sparkle:shortVersionString></item>'
printf '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" %s>\n<channel><title>Owlink</title>%s</channel>\n</rss>\n' "$NSDECL" "$OLDITEM" > "$W/compact-channel.xml"
printf '<?xml version="1.0" encoding="utf-8"?><rss version="2.0" %s><channel>%s</channel></rss>\n' "$NSDECL" "$OLDITEM" > "$W/one-line.xml"
for d in compact-channel one-line; do
    if item 1.4.0 --from "$W/$d.xml" && xmllint --noout "$FEEDOUT" && [ "$(items 1.4.0)" = 1 ] && [ "$(items 0.9.0)" = 1 ] \
        && [ "$(xmllint --xpath 'count(//item)' "$FEEDOUT")" = 2 ] && [ "$(grep -c '^edSignature: STUB$' "$FEEDOUT")" = 1 ] && [ -z "$(leftovers)" ]; then
        ok "appcast-item.sh adds the item inside the channel of $d.xml"
    else
        bad "appcast-item.sh with $d.xml: $(tail -2 "$W/item.out"); items: $(xmllint --xpath 'count(/rss/channel/item)' "$FEEDOUT" 2>&1) in channel, $(xmllint --xpath 'count(//item)' "$FEEDOUT" 2>&1) in all"
    fi
done

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

    # bundle-app.sh's ad-hoc signing (Scripts/sign-adhoc.sh) on a temp copy
    # of APP with the pinned Sparkle.framework added, as a --release build
    # has it (no release build is made; nothing is launched). Sparkle
    # 2.10.1's Downloader.xpc ships with no entitlements, so the copy's is
    # first given a test-only one; signing must keep it (a --deep first
    # pass dropped it), sign llama.framework on its own, and verify --deep
    # --strict.
    SP_SRC=$(find .build/artifacts -maxdepth 6 -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' 2>/dev/null | head -1)
    if [ -n "$SP_SRC" ]; then
        A="$W/adhoc/Owlink.app"
        mkdir -p "$W/adhoc"
        ditto "$APP" "$A" && ditto "$SP_SRC" "$A/Contents/Frameworks/Sparkle.framework"
        DL_XPC="$A/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
        cat > "$W/test-only.entitlements" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTS
        ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | tr -d '\0' | grep -o '<key>[^<]*</key><true/>' | tr '\n' ' '; }
        codesign -s - --force --entitlements "$W/test-only.entitlements" "$DL_XPC" 2>/dev/null
        before=$(ents "$DL_XPC")
        if [ "$before" != '<key>com.apple.security.network.client</key><true/> ' ]; then
            bad "sign-adhoc.sh: couldn't give the test copy's Downloader.xpc its test entitlement ($before)"
        elif ! out=$(Scripts/sign-adhoc.sh "$A" 2>&1); then
            bad "sign-adhoc.sh failed: $(tail -2 <<<"$out")"
        else
            after=$(ents "$DL_XPC")
            [ "$after" = "$before" ] && ok "sign-adhoc.sh: Downloader.xpc keeps its entitlements ($after)" \
                || bad "sign-adhoc.sh: Downloader.xpc entitlements were [$before], now [$after]"
            codesign --verify --strict "$A/Contents/Frameworks/llama.framework" 2>/dev/null \
                && codesign --verify --strict "$A/Contents/Frameworks/Sparkle.framework" 2>/dev/null \
                && codesign --verify --deep --strict "$A" 2>/dev/null \
                && ok "sign-adhoc.sh: llama.framework, Sparkle.framework and the app verify (the app --deep --strict)" \
                || bad "sign-adhoc.sh: a signature doesn't verify"
            [ "$(ents "$A/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc")" = "" ] \
                && ok "sign-adhoc.sh: Installer.xpc gets no entitlements" || bad "sign-adhoc.sh: Installer.xpc has entitlements"
        fi
    else
        echo "note: no Sparkle.framework in .build/artifacts (run swift build); ad-hoc Sparkle signing not checked"
    fi
fi

echo "updates-check: $pass passed, $failed failed"
[ $failed = 0 ]

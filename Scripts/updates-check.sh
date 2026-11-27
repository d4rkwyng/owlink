#!/bin/bash
# Checks the update plumbing (Sparkle 2, docs/updates.md) without a
# private key, a published feed or the network:
#  - release.sh uses the committed feed URL and public key
#    (Scripts/sparkle-defaults.sh) when CEDRIC_SPARKLE_FEED_URL /
#    CEDRIC_SPARKLE_PUBLIC_KEY are unset, and refuses to start, before it
#    builds or reads the keychain, whenever the feed URL, the public key,
#    the download URL or a private-key source is wrong or missing (always
#    also --dry-run, so even a broken guard couldn't sign or upload
#    anything; the script has no upload code at all);
#  - release.sh --appcast refuses a version a feed already lists before it
#    builds or touches the zip (dry run, from a temp copy of the scripts);
#  - bundle-app.sh refuses a non-HTTPS feed (bar a loopback http:// one);
#  - sign-sparkle.sh signs in Sparkle's order and refuses --deep;
#  - ed-verify.swift refuses malformed input;
#  - appcast-item.sh (the feed step) keeps the last signed feed when
#    signing or verifying fails, with a stub sign_update; finds duplicates
#    by XML value and adds the item inside the channel whatever the layout;
#  - with an APP (built without overrides): its Info.plist has the
#    committed feed and public key, a required signed feed, automatic
#    checks on and no silent installs, and bundle-app.sh's ad-hoc
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

# With no feed or key set, the committed ones are used: the first thing
# missing is then the download URL.
. Scripts/sparkle-defaults.sh
refuses "nothing set: the committed feed and key pass, the download URL is missing" "CEDRIC_SPARKLE_DOWNLOAD_URL is not set"
refuses "an http:// feed" "must be an https:// URL" CEDRIC_SPARKLE_FEED_URL=http://updates.example.invalid/appcast.xml
refuses "a loopback http:// feed (a local test's, never a release's)" "must be an https:// URL" \
    CEDRIC_SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml CEDRIC_SPARKLE_PUBLIC_KEY="$PUB" CEDRIC_SPARKLE_DOWNLOAD_URL="$DL"
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
    printf '<rss version="2.0"><item/></rss>\n' > "$W/no-channel.xml"
    refuses "an appcast copy with no channel" "CEDRIC_SPARKLE_APPCAST is not an appcast" "${SET[@]}" CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519 \
        CEDRIC_SPARKLE_APPCAST="$W/no-channel.xml"
else
    echo "note: no Sparkle tools in .build/artifacts (run swift build); appcast-copy refusal not checked"
fi

# Without --appcast the release flow is unchanged: the dry run starts, with
# the committed feed and key (no override note).
out=$(env -u CEDRIC_SPARKLE_FEED_URL -u CEDRIC_SPARKLE_PUBLIC_KEY CEDRIC_SIGN_ID=- Scripts/release.sh --dry-run --skip-notarize --skip-launch-check 2>&1); rc=$?
if [ $rc = 0 ] && grep -q '^+ Scripts/bundle-app.sh' <<<"$out" && grep -q 'Sparkle.framework/Versions/B/Autoupdate$' <<<"$out" && ! grep -q 'sign_update' <<<"$out" \
    && ! grep -q 'is overridden' <<<"$out"; then
    ok "release.sh without --appcast: dry run as before, committed feed and key, Sparkle signed in its order, no sign_update"
else
    bad "release.sh without --appcast (exit $rc): $(tail -3 <<<"$out")"
fi
out=$(env CEDRIC_SPARKLE_FEED_URL=$FEED CEDRIC_SPARKLE_PUBLIC_KEY="$PUB" CEDRIC_SIGN_ID=- Scripts/release.sh --dry-run --skip-notarize --skip-launch-check 2>&1); rc=$?
[ $rc = 0 ] && grep -q 'is overridden' <<<"$out" && ok "release.sh notes an overridden feed or key" \
    || bad "release.sh with an overridden feed and key (exit $rc): $(tail -2 <<<"$out")"
[ "$OWLINK_SPARKLE_FEED_URL" = https://owlink.app/appcast.xml ] \
    && [ "$(printf '%s' "$OWLINK_SPARKLE_PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] \
    && ok "sparkle-defaults.sh: the committed feed is https://owlink.app/appcast.xml and the key is 32 bytes of base64" \
    || bad "sparkle-defaults.sh: feed '$OWLINK_SPARKLE_FEED_URL', key '$OWLINK_SPARKLE_PUBLIC_KEY'"
grep -nE 'curl|scp |rsync|gh release|aws |gsutil|sftp|ftp ' Scripts/release.sh >/dev/null \
    && bad "release.sh has upload code" || ok "release.sh has no upload code (curl, scp, rsync, gh release, aws, gsutil, sftp)"

# bundle-app.sh: a non-HTTPS feed is refused before anything is built
# (only a loopback http:// one, for a local test, is taken).
for f in http://updates.example.invalid/appcast.xml http://localhost.example.invalid/a.xml \
         http://localhost:1@updates.example.invalid/a.xml http://127.0.0.2/a.xml; do
    out=$(CEDRIC_SPARKLE_FEED_URL=$f Scripts/bundle-app.sh --out "$W/out" 2>&1); rc=$?
    if [ $rc != 0 ] && grep -q "must be an https:// URL" <<<"$out" && ! grep -q '==> swift build' <<<"$out"; then
        ok "bundle-app.sh refuses the feed $f before building"
    else
        bad "bundle-app.sh with the feed $f (exit $rc): $(tail -2 <<<"$out")"
    fi
done

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
    if [ "${STUB_FAIL:-}" = dup ]; then
        # Signs "successfully" but leaves a second copy of each channel item
        # with version $STUB_DUP (verify still passes); a copy of what it
        # wrote goes to $STUB_DUP_COPY.
        /usr/bin/python3 -I - "$f" "$STUB_DUP" <<'PY'
import sys, copy, xml.etree.ElementTree as ET
URI = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", URI)
t = ET.parse(sys.argv[1]); ch = t.getroot().find("channel")
for it in list(ch.findall("item")):
    if any((e.text or "").strip() == sys.argv[2] for e in it if e.tag in ("{%s}version" % URI, "{%s}shortVersionString" % URI)):
        ch.append(copy.deepcopy(it))
t.write(sys.argv[1], encoding="utf-8", xml_declaration=True)
PY
        printf '<!-- sparkle-signatures:\nedSignature: STUB\n-->\n' >> "$f"
        cp "$f" "$STUB_DUP_COPY"
        exit 0
    fi
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
# sign_update saw only appcast.xml in a temp folder beside the feed, never
# the feed itself.
if [ "$(wc -l < "$W/stub.log" | tr -d ' ')" = 2 ] && ! awk '{ print $2 }' "$W/stub.log" | grep -vqE "^$W/dist/\.appcast-new\.[A-Za-z0-9]+/appcast\.xml$"; then
    ok "appcast-item.sh signs and verifies appcast.xml in a temp folder beside the feed, not the feed"
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
# Exactly one channel item with the version, or nothing is signed or
# replaced. A writer (stub `swift` on PATH, standing in for
# appcast-insert.swift) that puts the item under <rss>, outside the
# channel, in well-formed XML: refused before sign_update runs. A signer
# that leaves a second copy of the item while verify passes: refused after
# verify. Either way the feed is byte-identical and the temp folder gone.
mkdir -p "$W/fakeswift"
cat > "$W/fakeswift/swift" <<'STUB'
#!/bin/bash
# Test stub for `swift appcast-insert.swift FROM NEW VERSION …`: writes the
# item under <rss>, not under <channel>.
touch "$FAKESWIFT_RAN"
printf '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Owlink</title></channel><item><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString></item></rss>\n' "$4" "$4" > "$3"
STUB
chmod +x "$W/fakeswift/swift"
cp "$FEEDOUT" "$W/last-signed.xml"
rm -f "$W/fakeswift.ran"
rc=0; FAKESWIFT_RAN="$W/fakeswift.ran" PATH="$W/fakeswift:$PATH" item 1.6.0 --from "$FEEDOUT" || rc=$?
if [ $rc != 0 ] && [ -e "$W/fakeswift.ran" ] && grep -q "the new feed doesn't have exactly one channel item for 1.6.0" "$W/item.out" \
    && [ ! -s "$W/stub.log" ] && cmp -s "$FEEDOUT" "$W/last-signed.xml" && [ -z "$(leftovers)" ]; then
    ok "appcast-item.sh refuses a new feed with the item under <rss>, before signing; feed byte-identical, temp folder gone"
else
    bad "appcast-item.sh with the item under <rss> (exit $rc, writer $([ -e "$W/fakeswift.ran" ] && echo ran || echo "not run")): $(tail -2 "$W/item.out" | tr '\n' ' ') signer: $(tr '\n' ' ' < "$W/stub.log") leftovers: $(leftovers)"
fi
rm -f "$W/dup-seen.xml"
rc=0; STUB_FAIL=dup STUB_DUP=1.6.0 STUB_DUP_COPY="$W/dup-seen.xml" item 1.6.0 --from "$FEEDOUT" || rc=$?
if [ $rc != 0 ] && [ "$(items 1.6.0 "$W/dup-seen.xml" 2>/dev/null)" = 2 ] && grep -q "the signed feed doesn't have exactly one channel item for 1.6.0" "$W/item.out" \
    && [ "$(cut -d' ' -f1 "$W/stub.log" | tr '\n' ' ')" = "0 1 " ] && cmp -s "$FEEDOUT" "$W/last-signed.xml" && [ -z "$(leftovers)" ]; then
    ok "appcast-item.sh refuses a signed feed with the item twice after verify passes; feed byte-identical, temp folder gone"
else
    bad "appcast-item.sh with a duplicating signer (exit $rc, copies seen: $(items 1.6.0 "$W/dup-seen.xml" 2>&1)): $(tail -2 "$W/item.out" | tr '\n' ' ') signer: $(tr '\n' ' ' < "$W/stub.log") leftovers: $(leftovers)"
fi
# release.sh --appcast refuses a version a feed already lists in its
# preflight, before the build and before dist/Owlink-<version>.zip is
# removed or rewritten. Run from a copy of the repository's scripts in a
# temp folder (its own dist/, a stub bundle-app.sh, the stub sign_update),
# always --dry-run; the existing zip and feed must stay byte-identical.
R="$W/repo"
mkdir -p "$R/Scripts" "$R/Sources/CedricCore" "$R/dist"
cp Scripts/release.sh Scripts/sparkle-defaults.sh Scripts/appcast-versions.sh Scripts/sign-sparkle.sh "$R/Scripts/"
cp Sources/CedricCore/Version.swift "$R/Sources/CedricCore/"
printf '#!/bin/bash\ntouch "$(dirname "$0")/../bundle-app-ran"\n' > "$R/Scripts/bundle-app.sh"
chmod +x "$R/Scripts/bundle-app.sh"
RV=$(sed -n 's/.*static let source = "\([^"]*\)".*/\1/p' Sources/CedricCore/Version.swift)
head -c 4096 /dev/urandom > "$R/dist/Owlink-$RV.zip"
cp "$R/dist/Owlink-$RV.zip" "$W/zip-before"
# Sparkle's namespace under another prefix, the value on its own line.
printf '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle">\n<channel><item><s:shortVersionString>\n  %s\n</s:shortVersionString></item></channel>\n</rss>\n' "$RV" > "$W/has-version.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n<channel><item><sparkle:shortVersionString>%s</sparkle:shortVersionString></item></channel>\n</rss>\n' "${RV//./-}" > "$W/other-version.xml"
rel() { # dist-feed|keep [CEDRIC_SPARKLE_APPCAST] -> output in $W/rel.out
    # keep: leave whatever the test put at dist/appcast.xml.
    rm -f "$R/bundle-app-ran"
    if [ "$1" != keep ]; then
        rm -f "$R/dist/appcast.xml"
        [ -z "$1" ] || cp "$1" "$R/dist/appcast.xml"
    fi
    local rc=0
    env -u CEDRIC_VERSION -u TAG -u CEDRIC_SPARKLE_KEY_FILE "${SET[@]}" CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519 \
        CEDRIC_SPARKLE_BIN="$W/stub" CEDRIC_SIGN_ID="Developer ID Application: TEST ONLY (TEAMID)" \
        ${2:+CEDRIC_SPARKLE_APPCAST="$2"} "$R/Scripts/release.sh" --dry-run --appcast > "$W/rel.out" 2>&1 || rc=$?
    return $rc
}
untouched() { cmp -s "$R/dist/Owlink-$RV.zip" "$W/zip-before" && { [ -z "$1" ] || cmp -s "$R/dist/appcast.xml" "$1"; } && [ ! -e "$R/bundle-app-ran" ]; }
for how in "dist/appcast.xml" "CEDRIC_SPARKLE_APPCAST"; do
    rc=0
    if [ "$how" = dist/appcast.xml ]; then rel "$W/has-version.xml" || rc=$?; else rel "$W/other-version.xml" "$W/has-version.xml" || rc=$?; fi
    if [ $rc != 0 ] && grep -q "already has an item for $RV" "$W/rel.out" && ! grep -qE '^\+ (Scripts/bundle-app.sh|rm|ditto|codesign|xcrun)' "$W/rel.out" \
        && untouched "$([ "$how" = dist/appcast.xml ] && echo "$W/has-version.xml" || echo "$W/other-version.xml")"; then
        ok "release.sh --appcast refuses $RV listed in $how before building; the zip and feed are byte-identical"
    else
        bad "release.sh --appcast with $RV in $how (exit $rc): $(grep -m2 -E 'release.sh:|^\+ ' "$W/rel.out" | tr '\n' ' ')"
    fi
done
# A feed with ${RV//./-} only isn't a duplicate: the dry run goes on.
rc=0; rel "$W/other-version.xml" "$W/other-version.xml" || rc=$?
if [ $rc = 0 ] && ! grep -q 'already has an item' "$W/rel.out" && grep -q '^+ Scripts/bundle-app.sh' "$W/rel.out" && untouched "$W/other-version.xml"; then
    ok "release.sh --appcast: a feed with ${RV//./-} only doesn't stop a dry run of $RV"
else
    bad "release.sh --appcast with ${RV//./-} only (exit $rc): $(grep -m2 'release.sh:' "$W/rel.out")"
fi
# A folder at dist/appcast.xml, or a link to one: the final rename would
# put the signed feed inside it (dist/appcast.xml/appcast.xml) and report
# success. Preflight refuses before the build; the zip is byte-identical
# and the folder stays empty.
mkdir -p "$W/feed-folder"
for how in folder link; do
    rm -f "$R/dist/appcast.xml"
    if [ $how = folder ]; then mkdir "$R/dist/appcast.xml"; FOLDER="$R/dist/appcast.xml"; else ln -s "$W/feed-folder" "$R/dist/appcast.xml"; FOLDER="$W/feed-folder"; fi
    rc=0; rel keep || rc=$?
    if [ $rc != 0 ] && grep -q 'dist/appcast.xml is not a file' "$W/rel.out" && ! grep -qE '^\+ (Scripts/bundle-app.sh|security|rm|ditto|codesign|xcrun)' "$W/rel.out" \
        && untouched "" && [ -d "$R/dist/appcast.xml" ] && [ -z "$(ls -A "$FOLDER")" ]; then
        ok "release.sh --appcast refuses a $how at dist/appcast.xml before building; the zip is byte-identical, the folder empty"
    else
        bad "release.sh --appcast with a $how at dist/appcast.xml (exit $rc): $(grep -m2 -E 'release.sh:|^\+ ' "$W/rel.out" | tr '\n' ' ') folder: $(ls -A "$FOLDER" | tr '\n' ' ')"
    fi
    if [ $how = folder ]; then rmdir "$R/dist/appcast.xml"; else rm "$R/dist/appcast.xml"; fi
done
# appcast-item.sh refuses the same before it stages anything: sign_update
# never runs, the folder stays empty, no temp folder is left beside it.
mkdir -p "$W/outdir" "$W/outdir-target"
for how in folder link; do
    if [ $how = folder ]; then mkdir "$W/outdir/appcast.xml"; FOLDER="$W/outdir/appcast.xml"; else ln -s "$W/outdir-target" "$W/outdir/appcast.xml"; FOLDER="$W/outdir-target"; fi
    : > "$W/stub.log"
    rc=0; STUB_LOG="$W/stub.log" Scripts/appcast-item.sh --out "$W/outdir/appcast.xml" --sign-update "$W/stub/sign_update" \
        --version 2.1.0 --url https://downloads.example.invalid/v2.1.0/Owlink-2.1.0.zip --length 1 --signature "$SIG64" \
        -- --account owlink-test-only > "$W/item.out" 2>&1 || rc=$?
    if [ $rc != 0 ] && grep -q 'is not a file' "$W/item.out" && [ ! -s "$W/stub.log" ] && [ -z "$(ls -A "$FOLDER")" ] \
        && [ "$(ls -A "$W/outdir" | tr '\n' ' ')" = "appcast.xml " ]; then
        ok "appcast-item.sh refuses a $how at --out before staging; nothing signed, the folder empty"
    else
        bad "appcast-item.sh with a $how at --out (exit $rc): $(tail -2 "$W/item.out" | tr '\n' ' ') folder: $(ls -A "$FOLDER" | tr '\n' ' ') beside: $(ls -A "$W/outdir" | tr '\n' ' ')"
    fi
    if [ $how = folder ]; then rm -rf "$W/outdir/appcast.xml"; else rm "$W/outdir/appcast.xml"; fi
done
# A refused or failed run removes only its own temp folder: files beside
# the feed that look like its temp names (the old scheme's .xml) stay.
mkdir -p "$W/own"
printf 'keep me\n' > "$W/own/.appcast-new.KEEP01.xml"
printf 'keep me too\n' > "$W/own/.appcast-new.KEEP02"
cp "$W/own/.appcast-new.KEEP01.xml" "$W/keep1"; cp "$W/own/.appcast-new.KEEP02" "$W/keep2"
ownitem() { STUB_LOG="$W/stub.log" Scripts/appcast-item.sh --out "$W/own/appcast.xml" --sign-update "$W/stub/sign_update" \
    --version 2.0.0 --url https://downloads.example.invalid/v2.0.0/Owlink-2.0.0.zip --length 1 --signature "$SIG64" \
    "$@" -- --account owlink-test-only > "$W/item.out" 2>&1; }
rc=0; STUB_FAIL=sign ownitem || rc=$?
rc2=0; ownitem --from "$W/dup-lines.xml" || rc2=$?   # 1.3.0 there, so 2.0.0 is new: succeeds
rc3=0; ownitem --from "$W/own/appcast.xml" || rc3=$? # now a duplicate: refused
if [ $rc != 0 ] && [ $rc2 = 0 ] && [ $rc3 != 0 ] && cmp -s "$W/own/.appcast-new.KEEP01.xml" "$W/keep1" && cmp -s "$W/own/.appcast-new.KEEP02" "$W/keep2" \
    && [ "$(ls -A "$W/own" | tr '\n' ' ')" = ".appcast-new.KEEP01.xml .appcast-new.KEEP02 appcast.xml " ]; then
    ok "appcast-item.sh removes only its own temp folder (look-alike files beside the feed stay)"
else
    bad "appcast-item.sh cleanup (exits $rc $rc2 $rc3): $(ls -A "$W/own" | tr '\n' ' ')"
fi

# release.sh's own nested-code loop (not a dry run, everything stubbed):
# a find that prints one NUL-terminated path with a space in it and then
# fails must stop the release before Sparkle.framework or the app is
# signed. A temp repo whose bundle-app.sh makes an empty app skeleton;
# `find` and `codesign` on PATH are stubs (codesign only logs), so nothing
# is built, signed, notarized or launched.
R2="$W/repo2"
mkdir -p "$R2/Scripts" "$R2/Sources/CedricCore" "$W/relstub"
cp Scripts/release.sh Scripts/sparkle-defaults.sh "$R2/Scripts/"
cp Sources/CedricCore/Version.swift "$R2/Sources/CedricCore/"
cat > "$R2/Scripts/bundle-app.sh" <<STUB
#!/bin/bash
# Test stub: an app skeleton with version $RV, no code.
cd "\$(dirname "\$0")/.."
mkdir -p dist/Owlink.app/Contents/MacOS dist/Owlink.app/Contents/Frameworks/llama.framework dist/Owlink.app/Contents/Frameworks/Sparkle.framework
printf '<?xml version="1.0" encoding="UTF-8"?>\\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\\n' "$RV" > dist/Owlink.app/Contents/Info.plist
STUB
printf '#!/bin/bash\ntouch "$(dirname "$0")/../sign-sparkle-ran"\n' > "$R2/Scripts/sign-sparkle.sh"
cat > "$W/relstub/find" <<'STUB'
#!/bin/bash
# Test stub: the nested-code search lists one path (with a space), then fails.
case " $* " in *" -print0 "*) printf '%s\0' "$1/Frameworks/llama space.framework"; echo "find: $1/Resources/x: Permission denied" >&2; exit 1 ;; esac
exec /usr/bin/find "$@"
STUB
cat > "$W/relstub/codesign" <<'STUB'
#!/bin/bash
# Test stub: logs its last argument, signs nothing.
printf '%s\n' "${@: -1}" >> "$CODESIGN_LOG"
STUB
chmod +x "$R2/Scripts/bundle-app.sh" "$R2/Scripts/sign-sparkle.sh" "$W/relstub/find" "$W/relstub/codesign"
: > "$W/codesign.log"
rc=0; env -u CEDRIC_VERSION -u TAG -u CEDRIC_SPARKLE_FEED_URL -u CEDRIC_SPARKLE_PUBLIC_KEY PATH="$W/relstub:$PATH" CODESIGN_LOG="$W/codesign.log" \
    CEDRIC_SIGN_ID="Developer ID Application: TEST ONLY (TEAMID)" \
    "$R2/Scripts/release.sh" --host-arch --skip-notarize --skip-launch-check > "$W/rel2.out" 2>&1 || rc=$?
if [ $rc != 0 ] && grep -q 'could not find and sign all nested code' "$W/rel2.out" \
    && [ "$(cat "$W/codesign.log")" = "dist/Owlink.app/Contents/Frameworks/llama space.framework" ] \
    && [ ! -e "$R2/sign-sparkle-ran" ] && ! grep -q '^+ Scripts/sign-sparkle.sh' "$W/rel2.out"; then
    ok "release.sh stops when the nested-code search fails part way (path with a space signed whole), before Sparkle and the app"
else
    bad "release.sh with a failing nested-code search (exit $rc, sign-sparkle $([ -e "$R2/sign-sparkle-ran" ] && echo RAN || echo "not run")): codesign on: $(tr '\n' '|' < "$W/codesign.log") $(grep -m2 'release.sh:' "$W/rel2.out")"
fi

if [ -n "$APP" ]; then
    P="$APP/Contents/Info.plist"
    v() { plutil -extract "$1" raw "$P" 2>/dev/null; }
    [ "$(v SUFeedURL)" = "$OWLINK_SPARKLE_FEED_URL" ] \
        && ok "$APP: SUFeedURL is the committed $OWLINK_SPARKLE_FEED_URL" || bad "$APP: SUFeedURL is '$(v SUFeedURL)'"
    [ "$(v SUPublicEDKey)" = "$OWLINK_SPARKLE_PUBLIC_KEY" ] \
        && ok "$APP: SUPublicEDKey is the committed public key" || bad "$APP: SUPublicEDKey is '$(v SUPublicEDKey)'"
    [ "$(v SURequireSignedFeed)" = true ] && ok "$APP: SURequireSignedFeed" || bad "$APP: SURequireSignedFeed is '$(v SURequireSignedFeed)'"
    [ "$(v SUVerifyUpdateBeforeExtraction)" = true ] && ok "$APP: SUVerifyUpdateBeforeExtraction" || bad "$APP: SUVerifyUpdateBeforeExtraction"
    [ "$(v SUEnableAutomaticChecks)" = true ] && ok "$APP: automatic checks on by default" || bad "$APP: SUEnableAutomaticChecks is '$(v SUEnableAutomaticChecks)'"
    [ "$(v SUAutomaticallyUpdate)" = false ] && ok "$APP: no silent installs" || bad "$APP: SUAutomaticallyUpdate"
    # Nothing of Sparkle's is linked: a release build loads it after the first frame.
    otool -L "$APP/Contents/MacOS/Cedric" | grep -q Sparkle && bad "$APP links Sparkle at launch" || ok "$APP doesn't link Sparkle (a release build dlopens it after the first frame)"

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
    # A nested-code search that fails part way (an unreadable folder in
    # the bundle, after llama.framework is found) stops sign-adhoc.sh.
    B="$W/findfail/Owlink.app"
    mkdir -p "$W/findfail" && ditto "$APP" "$B" && mkdir -p "$B/Contents/Resources/zz-unreadable" && chmod 000 "$B/Contents/Resources/zz-unreadable"
    rc=0; out=$(Scripts/sign-adhoc.sh "$B" 2>&1) || rc=$?
    chmod 755 "$B/Contents/Resources/zz-unreadable"
    if [ $rc != 0 ] && grep -q 'could not find and sign all nested code' <<<"$out" && ! grep -qF "$B: replacing existing signature" <<<"$out"; then
        ok "sign-adhoc.sh stops when the search for nested code fails, before signing the app"
    else
        bad "sign-adhoc.sh with a failing nested-code search (exit $rc): $(tail -2 <<<"$out")"
    fi
fi

echo "updates-check: $pass passed, $failed failed"
[ $failed = 0 ]

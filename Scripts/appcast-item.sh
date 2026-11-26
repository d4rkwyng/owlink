#!/bin/bash
# Adds one update's <item> to an appcast and signs the feed, for
# Scripts/release.sh --appcast (docs/updates.md).
#
# OUT, the last signed feed, is never edited in place. The new feed is
# written to a temp file beside OUT whose name ends in .xml (sign_update
# chooses feed signing by the extension), with the item added as a direct
# child of /rss/channel by an XML parser (Scripts/appcast-insert.swift),
# checked with xmllint and for exactly one channel item with VERSION
# (Scripts/appcast-versions.sh), signed and verified there, and only then renamed over OUT. Any failure leaves OUT
# byte for byte as it was, so the run can be retried (the version is not
# yet in OUT, so it isn't refused as a duplicate).
#
#   Scripts/appcast-item.sh --out FEED --sign-update PATH --version V \
#       --url ENCLOSURE_URL --length BYTES --signature ED_SIGNATURE \
#       [--from FEED] [-- sign_update key arguments…]
#
#   --from   the feed to add the item to (may be OUT itself); without it a
#            new feed is started
#   after -- the private-key source for sign_update (--account NAME or
#            --ed-key-file FILE); this script never reads the key itself
set -euo pipefail
fail() { echo "appcast-item.sh: $*" >&2; exit 1; }

OUT="" SIGN_UPDATE="" VERSION="" URL="" LENGTH="" EDSIG="" FROM=""
KEY_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=${2-}; shift 2 ;;
        --sign-update) SIGN_UPDATE=${2-}; shift 2 ;;
        --version) VERSION=${2-}; shift 2 ;;
        --url) URL=${2-}; shift 2 ;;
        --length) LENGTH=${2-}; shift 2 ;;
        --signature) EDSIG=${2-}; shift 2 ;;
        --from) FROM=${2-}; shift 2 ;;
        --) shift; KEY_ARGS=("$@"); break ;;
        *) fail "unknown argument $1" ;;
    esac
done
[ -n "$OUT" ] && [ -n "$SIGN_UPDATE" ] && [ -n "$VERSION" ] && [ -n "$URL" ] && [ -n "$LENGTH" ] && [ -n "$EDSIG" ] \
    || fail "needs --out, --sign-update, --version, --url, --length and --signature"
case "$OUT" in *.xml) ;; *) fail "--out must end in .xml" ;; esac
case "$VERSION" in *[!0-9A-Za-z.+-]*) fail "--version $VERSION has characters an appcast can't hold" ;; esac
case "$LENGTH" in *[!0-9]*) fail "--length must be a number of bytes" ;; esac
case "$EDSIG" in *[!A-Za-z0-9+/=]*) fail "--signature is not base64" ;; esac
case "$URL" in https://?*) ;; *) fail "--url must be an https:// URL" ;; esac
case "$URL" in *[\<\>\&\"\'[:space:]]*) fail "--url may not hold spaces or < > & quotes" ;; esac
[ -x "$SIGN_UPDATE" ] || fail "no sign_update at $SIGN_UPDATE"
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -n "$FROM" ]; then
    [ -f "$FROM" ] || fail "$FROM is not a file"
    # By XML value: Sparkle's fields by namespace URI, the text as text.
    have=$("$HERE/appcast-versions.sh" "$FROM" "$VERSION") || fail "can't read $FROM as an appcast"
    [ "$have" = 0 ] || fail "$FROM already has an item for $VERSION"
fi

DIR=$(dirname "$OUT")
mkdir -p "$DIR"
# mktemp reserves a unique name; the feed itself is that name plus .xml,
# created only if nothing is there (noclobber). Both go on any exit; on
# success the .xml one has been renamed to OUT by then.
STEM=$(mktemp "$DIR/.appcast-new.XXXXXX") || fail "can't make a temp file in $DIR"
NEW="$STEM.xml"
trap 'rm -f "$STEM" "$NEW"' EXIT
(set -C; : > "$NEW") 2>/dev/null || fail "$NEW already exists"

# The item goes in as a direct child of /rss/channel, through an XML
# parser (Scripts/appcast-insert.swift), never by line.
swift "$HERE/appcast-insert.swift" "${FROM:--}" "$NEW" "$VERSION" "$URL" "$LENGTH" "$EDSIG" \
    "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" || fail "could not add the item; $OUT is unchanged"
xmllint --noout "$NEW" || fail "the new feed is not well-formed XML; $OUT is unchanged"
# Exactly one direct channel item has this version, or nothing is signed.
one() { [ "$("$HERE/appcast-versions.sh" "$NEW" "$VERSION" 2>/dev/null)" = 1 ]; }
one || fail "the new feed doesn't have exactly one channel item for $VERSION; $OUT is unchanged"
echo "+ $(printf '%q ' "$SIGN_UPDATE" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$NEW")"
"$SIGN_UPDATE" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$NEW" || fail "sign_update could not sign the new feed; $OUT is unchanged"
"$SIGN_UPDATE" --verify ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$NEW" || fail "the new feed's signature doesn't verify; $OUT is unchanged"
xmllint --noout "$NEW" || fail "the signed feed is not well-formed XML; $OUT is unchanged"
one || fail "the signed feed doesn't have exactly one channel item for $VERSION; $OUT is unchanged"
# Same folder, so a rename: OUT is either the old feed or the new one.
mv -f "$NEW" "$OUT"
echo "Wrote $OUT (item $VERSION added, feed signed and verified)"

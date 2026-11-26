#!/bin/bash
# Prints how many direct items of an appcast's channel (/rss/channel/item)
# carry VERSION, for Scripts/appcast-item.sh and Scripts/release.sh
# --appcast (docs/updates.md). An item carries it when one of its Sparkle
# fields, sparkle:version or sparkle:shortVersionString (as an element, or
# as an attribute of its enclosure, the older layout), has VERSION as its
# text once surrounding whitespace is dropped. Sparkle's fields are found
# by namespace URI, so any prefix works; the text is compared as text, not
# as a pattern.
#
#   Scripts/appcast-versions.sh FEED VERSION
#
# Exit 0 with the count on stdout; 2 if FEED isn't well-formed XML with
# exactly one /rss/channel, or VERSION has characters an appcast version
# can't hold. Uses only xmllint (stock macOS), never the network.
set -euo pipefail
fail() { echo "appcast-versions.sh: $*" >&2; exit 2; }
[ $# = 2 ] || { sed -n '2,15p' "$0" >&2; exit 2; }
FEED=$1 VERSION=$2
[ -n "$VERSION" ] || fail "empty version"
# This also keeps quotes out of the XPath literal below.
case "$VERSION" in *[!0-9A-Za-z.+-]*) fail "version $VERSION has characters an appcast can't hold" ;; esac
[ -f "$FEED" ] || fail "$FEED is not a file"
x() { xmllint --nonet --xpath "$1" "$FEED" 2>/dev/null; }
channels=$(x 'count(/rss/channel)') || fail "$FEED is not well-formed XML"
[ "$channels" = 1 ] || fail "$FEED has $channels /rss/channel elements, not one"
NS=http://www.andymatuschak.org/xml-namespaces/sparkle
FIELD="namespace-uri()='$NS' and (local-name()='version' or local-name()='shortVersionString') and normalize-space(.)='$VERSION'"
x "count(/rss/channel/item[*[$FIELD] or enclosure/@*[$FIELD]])" || fail "xmllint could not read $FEED"
echo

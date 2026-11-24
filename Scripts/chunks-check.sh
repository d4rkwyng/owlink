#!/bin/zsh
# Chunked storage check, no app: compiles Scripts/chunks-check.swift with
# the app's ChunkedContentStorage and CedricCore's LargeDocument and
# LineIndex, and runs it. It compares the chunking enumeration with
# NSTextContentStorage's own from every offset (short lines), walks long
# lines in chunks across edits, and lays out a pasted 30,000-character
# line in a many-line text in a TextKit 2 view that is never shown
# (default 60,000 lines; the 55 MiB log is Scripts/bigfile-check.sh's).
#
#   Scripts/chunks-check.sh [LINES]
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d "${TMPDIR:-/tmp}/cedric-chunks.XXXXXX")
trap 'rm -rf "$W"' EXIT
# The app target's file imports CedricCore; here its two files are compiled in.
sed '/^import CedricCore$/d' Sources/CedricApp/ChunkedContentStorage.swift \
    | sed 's/^final class ChunkedContentStorage/class ChunkedContentStorage/' > "$W/ChunkedContentStorage.swift"
# With several files, top-level code must be in main.swift.
cp Scripts/chunks-check.swift "$W/main.swift"
xcrun swiftc -O -o "$W/chunks-check" "$W/main.swift" "$W/ChunkedContentStorage.swift" \
    Sources/CedricCore/LargeDocument.swift Sources/CedricCore/LineIndex.swift
"$W/chunks-check" "$@"

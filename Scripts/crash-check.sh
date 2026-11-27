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
#      edit comes back unsaved; the next ⌘S into that folder saves the
#      edit and leaves the partial .owlink-save-* file (and every other
#      file there) alone: nothing deletes those automatically.
#   4. A crash (CEDRIC_TEST_ABORT_AFTER: abort()) instead of kill -9, as 1
#      and 2: an untitled tab and an edited file.
#   5. Two windows, one tab a 30 MB file in large-document mode: the
#      session store never holds its text; it reopens from disk.
#   6. Edited files deleted and renamed while the app was dead: restored
#      unsaved with the "deleted or moved" notice, not dropped.
#   7. A truncated session.json: the app launches, keeps the bad file
#      aside (session.unreadable-*.json) and loses no unsaved text.
#   8. Killed between writing a new tab's buffer and committing the
#      session that names it, with an older valid session in place
#      (CEDRIC_TEST_HOLD_SESSION_COMMIT): the text comes back, and
#      survives the next save's prune.
#   9. Two quick changes, then steady typing, killed while it goes on
#      (after a quiet spell, and right after a save): the leading save
#      was not put off by the typing.
#  10. Quit while every session write fails (CEDRIC_TEST_SESSION_WRITE_FAIL):
#      the app stays open.
#  11. A buffer that can't be read at launch: kept, said, never pruned.
#  12. A closed tab with unsaved text, reopened (⇧⌘T), killed before the
#      session that lists it open is committed; its closing date passes
#      ClosedTabs.keepDays before the next launch: it comes back open
#      with its text, not expired with it.
#  13. Two Owlinks on one session folder: the second (launched while
#      the first runs, before it backs up a new tab, and typing after
#      it) can't claim the folder's lock, so it saves and prunes nothing
#      there: it writes its own store (instances/<uuid>/), so its quit
#      needn't ask. The first's text survives and comes back after a kill.
#  14. A second Owlink's own crash: it types, its timed backup runs, it
#      is killed: the text is on disk in its own store. The first quits;
#      the next writer adopts the dead one's text at launch (killed at
#      its first commit: the dead store is still there, the text already
#      here; then relaunched: committed, the dead store removed), while
#      a third Owlink, still running, keeps its store untouched.
#
# Safety: the temp root must be this user's own 0700 folder, neither in
# nor around the real ~/Library/Application Support/Cedric (compared by
# filesystem identity, device and inode, up every ancestor both ways, and
# by case-folded physical path: a case-insensitive volume spells one
# folder many ways). Once verified, the root is used only by its verified
# physical path, pinned by identity: every child made, launch, dump and
# the final cleanup first checks the root still is that folder (the
# cleanup deletes nothing otherwise). Each session directory is made by
# this script directly in that root (one plain name, no link) and checked
# again before every launch and dump. The app bundle is cloned into the
# root once and only that copy is run: it must report "dev hooks: on"
# (a release build ignores CEDRIC_SESSION_DIR and would use the real
# session), asked with restore and session saving off, and its binary's
# SHA-256 is checked before every launch. Every launch passes
# CEDRIC_DISPOSABLE_STORE (the session folder's identity): the running
# binary itself refuses to start unless its session folder is that folder
# and outside the real one (DisposableStore), and the script fails closed
# unless it says "disposable store: verified". Only processes this script
# started are killed, and a reaped one is no longer tracked. Relaunches
# pass -ApplePersistenceIgnoreState YES. Needs a GUI session (works with
# the screen locked).
#
#   Scripts/crash-check.sh [APP]     default "dist/Owlink.app"
#   Scripts/crash-check.sh --self-test-paths
#       checks the directory guards against symbolic-link aliases in a
#       scratch folder (a decoy stands in for the real session); launches
#       nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
physical() { python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
ident() { stat -f %d:%i "$1" 2>/dev/null; }
# in_or_at A B: path A is B or inside it: by case-folded physical path, or
# by identity (an existing ancestor of A, A included, is B).
in_or_at() {
    python3 -I - "$1" "$2" <<'PY'
import os, sys
a, b = (os.path.realpath(p) for p in sys.argv[1:3])
if a.casefold() == b.casefold() or a.casefold().startswith(b.casefold().rstrip("/") + "/"): sys.exit(0)
try: bs = os.stat(b)
except OSError: sys.exit(1)
p = a
while True:
    try:
        s = os.stat(p)
        if (s.st_dev, s.st_ino) == (bs.st_dev, bs.st_ino): sys.exit(0)
    except OSError: pass
    if p == "/": break
    p = os.path.dirname(p)
sys.exit(1)
PY
}
# The real session and the Cedric folder around it (Replace in Files' undo
# copies, the CLI token): a root may be neither in nor around it.
REAL_SESSION=$(physical "$HOME/Library/Application Support/Cedric")
# verify_root DIR: prints DIR's physical path if it is a safe temp root.
verify_root() {
    local p; p=$(physical "$1")
    [ -d "$p" ] && [ ! -L "$p" ] || { echo "crash-check: REFUSED: temp root $1 is not a folder" >&2; return 2; }
    [ "$(stat -f %u "$p")" = "$(id -u)" ] && [ "$(stat -f %Lp "$p")" = 700 ] \
        || { echo "crash-check: REFUSED: temp root $p is not this user's own 0700 folder" >&2; return 2; }
    if in_or_at "$p" "$REAL_SESSION" || in_or_at "$REAL_SESSION" "$p" || [ "$p" = / ]; then
        echo "crash-check: REFUSED: temp root $1 (physically $p) is in or around the real session $REAL_SESSION" >&2; return 2
    fi
    echo "$p"
}
# check_child DIR: DIR is an existing session folder this script made: one
# plain name directly in $W, a real folder (not a link), physically in the
# verified root $WP (the same as $W once verified: root_ok).
check_child() {
    root_ok || return 2
    local name=${1#"$W"/}
    case "$1" in "$W"/?*) ;; *) echo "crash-check: REFUSED: session dir $1 is not inside $W" >&2; return 2 ;; esac
    case "$name" in */*|.|..|*[!A-Za-z0-9._-]*) echo "crash-check: REFUSED: session dir $1 is not one plain name in $W" >&2; return 2 ;; esac
    [ ! -L "$1" ] && [ -d "$1" ] || { echo "crash-check: REFUSED: session dir $1 is a link or not a folder" >&2; return 2; }
    local p; p=$(physical "$1")
    [ "$p" = "$WP/$name" ] || { echo "crash-check: REFUSED: session dir $1 is physically $p, not in $WP" >&2; return 2; }
    [ "$(ident "$(dirname "$p")")" = "$ROOT_ID" ] || { echo "crash-check: REFUSED: session dir $1 is not in the pinned root" >&2; return 2; }
    ! in_or_at "$p" "$REAL_SESSION" || { echo "crash-check: REFUSED: session dir $1 is the real session" >&2; return 2; }
}
# root_ok: $W is still the verified root: the same physical path and the
# same folder (identity pinned when it was verified), not a link.
root_ok() {
    [ -n "${ROOT_ID:-}" ] && [ "$W" = "$WP" ] && [ ! -L "$W" ] && [ -d "$W" ] && [ "$(ident "$W")" = "$ROOT_ID" ] \
        && [ "$(physical "$W")" = "$WP" ] || { echo "crash-check: REFUSED: the temp root $W is no longer the verified folder" >&2; return 2; }
}
# Removes the root, only if it still is the verified folder.
cleanup_root() {
    root_ok || { echo "crash-check: REFUSED: not cleaning up $W" >&2; return 2; }
    chmod -R u+rwX "$W" 2>/dev/null || true
    rm -rf "$W"
}
# child NAME: makes the session folder $W/NAME (it must not exist yet), checks it, prints it.
child() {
    root_ok || return 2
    local d="$W/$1"
    [ ! -e "$d" ] && [ ! -L "$d" ] || { echo "crash-check: REFUSED: $d already exists" >&2; return 2; }
    case "$1" in */*|.|..|*[!A-Za-z0-9._-]*) echo "crash-check: REFUSED: '$1' is not a plain name" >&2; return 2 ;; esac
    mkdir -m 700 "$d" && check_child "$d" && echo "$d"
}

if [ "${1:-}" = "--self-test-paths" ]; then
    # A scratch folder; a decoy plays the real session. Nothing is launched.
    X=$(physical "$(mktemp -d)")
    trap 'rm -rf "$X"' EXIT
    REAL_SESSION="$X/decoy-session"; mkdir -m 700 "$REAL_SESSION" "$REAL_SESSION/inner"
    W=""; WP=""; ROOT_ID=""
    echo "keep me" > "$REAL_SESSION/session.json"
    pass=0; failed=0
    t() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else echo "paths self-test: FAIL $3 (got $1, want $2)" >&2; failed=1; fi; }
    rc() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
    mkdir -m 700 "$X/root"
    ln -s "$REAL_SESSION" "$X/alias-to-session"; ln -s "$REAL_SESSION/inner" "$X/alias-inside-session"
    ln -s "$X" "$REAL_SESSION/../alias-around"
    t "$(rc verify_root "$X/root")" 0 "a plain 0700 root is accepted"
    t "$(rc verify_root "$X/alias-to-session")" 2 "a root that is a link to the (decoy) real session"
    t "$(rc verify_root "$X/alias-inside-session")" 2 "a root that is a link into the (decoy) real session"
    t "$(rc verify_root "$X")" 2 "a root around the (decoy) real session"
    t "$(rc verify_root "$X/alias-around")" 2 "a link to a root around the (decoy) real session"
    # The (decoy) real session spelled with other case: on a
    # case-insensitive volume it is the same folder.
    if [ -d "$X/DECOY-SESSION" ]; then
        t "$(rc verify_root "$X/DECOY-SESSION")" 2 "the (decoy) real session spelled in other case"
        t "$(rc verify_root "$X/DECOY-SESSION/inner")" 2 "a folder in it spelled in other case"
    else echo "paths self-test: NOTE case-sensitive volume, case variants not tried"; fi
    W="$X/root"; WP=$(verify_root "$W"); ROOT_ID=$(ident "$WP")
    t "$(rc child s1)" 0 "a new plain child"
    t "$(rc check_child "$W/s1")" 0 "the child checks"
    t "$(rc child s1)" 2 "a child that exists already"
    ln -s "$REAL_SESSION" "$W/sl"
    t "$(rc check_child "$W/sl")" 2 "a child that is a link to the (decoy) real session"
    t "$(rc child sl)" 2 "making a child where a link is"
    mkdir -m 700 "$W/real2"; ln -s "$W/real2" "$W/sl2"
    t "$(rc check_child "$W/sl2")" 2 "a child that is a link within the root"
    t "$(rc check_child "$W/../alias-to-session")" 2 "an escaping child (..)"
    t "$(rc check_child "$W/a/b")" 2 "a nested child"
    t "$(rc child "../escape")" 2 "making an escaping child"
    t "$(rc check_child "$X/root-other")" 2 "a sibling of the root"
    touch "$W/file"
    t "$(rc check_child "$W/file")" 2 "a child that is a file"
    # The root used through an alias, not its verified path: refused.
    ln -s "$W" "$X/root-alias"
    W0=$W; W="$X/root-alias"
    t "$(rc check_child "$X/root-alias/s1")" 2 "a child through an alias of the verified root (only the verified path is used)"
    t "$(rc root_ok)" 2 "the root through an alias"
    rm "$X/root-alias"; ln -s "$REAL_SESSION" "$X/root-alias"; mkdir -m 700 "$REAL_SESSION/s1"
    t "$(rc check_child "$X/root-alias/s1")" 2 "the alias turned to the (decoy) real session after the root was verified"
    rmdir "$REAL_SESSION/s1"
    W=$W0
    # The root replaced by another folder at the same path after it was
    # verified: nothing more is made, launched or cleaned up in it.
    t "$(rc root_ok)" 0 "the pinned root"
    mv "$W" "$X/root-moved"; mkdir -m 700 "$W"
    t "$(rc root_ok)" 2 "another folder at the root's path"
    t "$(rc child s9)" 2 "making a child in a replaced root"
    t "$(rc cleanup_root)" 2 "cleaning up a replaced root"
    t "$([ -d "$W" ] && echo kept)" kept "the replacement is left alone"
    rmdir "$W"; mv "$X/root-moved" "$W"
    t "$(ls -A "$REAL_SESSION" | tr '\n' ' ')" "inner session.json " "the decoy is untouched"
    t "$(cat "$REAL_SESSION/session.json")" "keep me" "the decoy's file is untouched"
    rm -f "$REAL_SESSION/../alias-around"
    [ $failed = 0 ] && echo "paths self-test: all OK ($pass checks)" || echo "paths self-test: FAILED ($pass OK)" >&2
    exit $failed
fi

APP="${1:-dist/Owlink.app}"
[ -x "$APP/Contents/MacOS/Cedric" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
. Scripts/check-env.sh
# Refused from the bundle alone, before anything runs (check-env.sh).
cedric_require_check_build "$APP"
PIDS=()
W0=$(mktemp -d)
# Verified before anything else: the preflight's own folder goes in it.
WP=$(verify_root "$W0") || { rmdir "$W0" 2>/dev/null || true; exit 2; }
# From here on only the verified path, pinned by identity (root_ok).
W=$WP; ROOT_ID=$(ident "$WP")
# The same folder as the app spells the files it opens (it records
# /var/... for /private/var/...): used only for the documents handed to it
# and the paths expected back, and only once it is checked to be the
# pinned root itself.
F=${WP#/private}
[ "$F" = "$WP" ] || { [ "$(physical "$F")" = "$WP" ] && [ "$(ident "$F")" = "$ROOT_ID" ]; } || F=$WP
# A tracked pid is killed only while it is still this script's child
# running the app binary (a reaped pid can be reused by anything).
kill_ours() { # PID
    kill -0 "$1" 2>/dev/null || return 0
    [ "$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')" = "$$" ] || return 0
    case "$(ps -o comm= -p "$1" 2>/dev/null)" in *"/Contents/MacOS/Cedric") kill -9 "$1" 2>/dev/null || true ;; esac
}
cleanup() {
    for p in ${PIDS[@]+"${PIDS[@]}"}; do kill_ours "$p"; done
    cleanup_root || true
}
trap cleanup EXIT
untrack() { # PID: reaped, no longer ours to kill
    local keep=() q
    for q in ${PIDS[@]+"${PIDS[@]}"}; do [ "$q" != "$1" ] && keep+=("$q"); done
    PIDS=(${keep[@]+"${keep[@]}"})
}
unset CEDRIC_OPEN CEDRIC_TEST_TYPE CEDRIC_TEST_TYPE_UNTITLED CEDRIC_TEST_TYPE_UNTITLED_DELAY CEDRIC_NO_RESTORE CEDRIC_NO_SESSION_SAVE CEDRIC_SESSION_DIR \
    CEDRIC_TEST_TYPE_BURST CEDRIC_TEST_HOLD_SESSION_COMMIT CEDRIC_TEST_SESSION_WRITE_FAIL CEDRIC_TEST_QUIT_SAVE_CHOICE
# The bundle, cloned into the root (APFS clone: no copy of the bytes):
# what is probed is what runs, whatever happens to $APP meanwhile.
root_ok || exit 2
cedric_isolate "$W"
# A 30-day-old Replace in Files undo operation in this run's ReplaceUndo:
# the launches' prune must take it (checked at the end), which shows they
# pruned this folder and not the real one.
CANARY="$CEDRIC_REPLACE_UNDO_DIR/$(uuidgen)"
mkdir -p "$CANARY"; touch -t "$(date -v-30d +%Y%m%d%H%M)" "$CANARY"
mkdir -m 700 "$W/app" && cp -cR "$APP" "$W/app/Owlink.app" 2>/dev/null || cp -R "$APP" "$W/app/Owlink.app"
cedric_require_check_build "$W/app/Owlink.app"
BIN="$W/app/Owlink.app/Contents/MacOS/Cedric"
BIN_SHA=$(shasum -a 256 "$BIN" | cut -d' ' -f1)
bin_ok() { [ "$(shasum -a 256 "$BIN" | cut -d' ' -f1)" = "$BIN_SHA" ] || { echo "crash-check: REFUSED: the probed binary changed" >&2; return 2; }; }
# Preflight, before anything destructive: a check build ("dev hooks: on"),
# asked with restore and session saving off, so even a release build
# touches no session here. CEDRIC_LLAMA_CHECK prints the hook status first.
P=$(child preflight)
pre=$(env CEDRIC_SESSION_DIR="$P" CEDRIC_DISPOSABLE_STORE="$(ident "$P")" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_LLAMA_CHECK=1 \
    perl -e 'alarm 60; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null || true)
if ! printf '%s\n' "$pre" | grep -qx 'dev hooks: on'; then
    echo "crash-check: REFUSED: $APP is not a check build (no 'dev hooks: on'; got '$(printf '%s' "$pre" | head -1)'). It would ignore CEDRIC_SESSION_DIR and use the real session. Build one with Scripts/bundle-app.sh." >&2
    exit 2
fi
echo "crash-check: preflight: dev hooks: on"

fail=0; oks=0
ok() { echo "crash-check: OK   $1"; oks=$((oks + 1)); }
bad() { echo "crash-check: FAIL $1" >&2; fail=1; }

sha_s() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }
sha_f() { shasum -a 256 "$1" | cut -d' ' -f1; }
len16() { python3 -I -c 'import sys; print(len(sys.argv[1].encode("utf-16-le")) // 2)' "$1"; }

# launch DIR OUT [VAR=value ...]: start the app on session DIR, stdout to OUT; sets $pid.
# The app checks DIR's identity itself (CEDRIC_DISPOSABLE_STORE) before it
# opens the store; without its "verified" line the run stops here.
launch() {
    local dir=$1 out=$2; shift 2
    check_child "$dir" && bin_ok || exit 2
    env CEDRIC_SESSION_DIR="$dir" CEDRIC_DISPOSABLE_STORE="$(ident "$dir")" "$@" "$BIN" -ApplePersistenceIgnoreState YES > "$out" 2>/dev/null &
    pid=$!
    PIDS+=("$pid")
    for _ in $(seq 1 200); do
        grep -q '^disposable store: verified' "$out" 2>/dev/null && return 0
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
    done
    grep -q '^disposable store: verified' "$out" 2>/dev/null && return 0
    echo "crash-check: REFUSED: the app didn't verify its session folder $dir: $(grep '^disposable store:' "$out" | head -1)" >&2
    kill9 "$pid"; exit 2
}
kill9() { kill_ours "$1"; wait "$1" 2>/dev/null || true; untrack "$1"; }
quit_app() {
    osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1); if (a) a.terminate; ''" >/dev/null
    for _ in $(seq 1 20); do kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null || true; untrack "$1"; return 0; }; sleep 0.5; done
    bad "the app did not quit"; kill9 "$1"
}
# The restored state, printed by a relaunch that saves nothing.
dump() { # DIR
    check_child "$1" && bin_ok || exit 2
    env CEDRIC_SESSION_DIR="$1" CEDRIC_DISPOSABLE_STORE="$(ident "$1")" CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 \
        perl -e 'alarm 60; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null || true
    grep -q '^disposable store: verified' "$W/dump.txt" || { echo "crash-check: REFUSED: the dump didn't verify its session folder $1" >&2; exit 2; }
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
S=$(child s1a)
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
S=$(child s1b)
launch "$S" "$W/out1b" CEDRIC_TEST_TYPE_UNTITLED="$T1"
typed_at "$W/out1b" >/dev/null
sleep 2.5
kill9 $pid
dump "$S"
expect_tab "1b: killed after the interval: untitled tab back, exact text, caret" - "$T1"
expect_count "1b" 1

# 2. A saved file edited, not saved, kill -9.
printf 'first line\nsecond line\n' > "$F/notes.txt"
orig=$(sha_f "$F/notes.txt")
T2=$(printf 'first line\nsecond line\n edited, not saved')
S=$(child s2)
launch "$S" "$W/out2" CEDRIC_OPEN="$F/notes.txt" CEDRIC_TEST_TYPE=" edited, not saved"
typed_at "$W/out2" >/dev/null
wait_holds "$S" "$F/notes.txt" "$(sha_s "$T2")" 10 || bad "2: the edit never reached the session store"
kill9 $pid
expect_disk "2: the file on disk is untouched" "$F/notes.txt" "$orig"
dump "$S"
expect_tab "2: the edit is back, unsaved, exact text, caret" "$F/notes.txt" "$T2"
expect_count "2" 1

# 3. kill -9 while ⌘S is writing a 16 MB file, held half way.
python3 -I -c '
import sys
row = "row %07d of a big file that is being saved when the app is killed\n"
open(sys.argv[1], "w").write("".join(row % i for i in range(16_000_000 // len(row % 0))))' "$F/big.txt"
orig=$(sha_f "$F/big.txt")
T3sha=$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read() + b" saved half way").hexdigest())' "$F/big.txt")
T3len=$(python3 -I -c 'import sys; print(len(open(sys.argv[1]).read()) + len(" saved half way"))' "$F/big.txt")
S=$(child s3)
launch "$S" "$W/out3" CEDRIC_OPEN="$F/big.txt" CEDRIC_TEST_TYPE=" saved half way" CEDRIC_TEST_SAVE_PAUSE="$W/paused" CEDRIC_TEST_SAVE_PAUSE_AFTER=4
typed_at "$W/out3" >/dev/null
wait_holds "$S" "$F/big.txt" "$T3sha" 15 || bad "3: the edit never reached the session store"
for _ in $(seq 1 200); do [ -s "$W/paused" ] && break; sleep 0.1; done
if [ -s "$W/paused" ]; then
    half=$(head -1 "$W/paused")
    tmp=$(ls -A "$W" | grep '^\.owlink-save-' | head -1 || true)
    tsize=$([ -n "$tmp" ] && stat -f %z "$W/$tmp" || echo none)
    [ "$tsize" = "$half" ] && ok "3: the save is half way: $half of $((half * 2)) bytes in its new file" || bad "3: save in progress, new file size $tsize, want $half"
else bad "3: the save never reached the pause"; fi
expect_disk "3: during the save the file is still the old one" "$F/big.txt" "$orig"
kill9 $pid
expect_disk "3: after the kill the file is the old one, not torn" "$F/big.txt" "$orig"
dump "$S"
pat="^exact: win=[0-9]+ name=big.txt file=$F/big.txt dirty=true sha=$T3sha len=$T3len sel=$T3len,0 large=-"
grep -E -q -- "$pat" "$W/dump.txt" && ok "3: the edit is back, unsaved, exact text (16 MB), caret" || bad "3: no '$pat'"
expect_count "3" 1
left=$(ls -A "$W" | grep -c '^\.owlink-save-' || true)
echo "crash-check: NOTE 3: $left partial .owlink-save-* file(s) left beside the file by the killed save"
# The next save into that folder deletes nothing beside the file: not the
# killed save's partial file, a look-alike name, or a link with the name.
touch "$W/.owlink-save-not-a-uuid"
ln -s "$F/notes.txt" "$W/.owlink-save-$(python3 -I -c 'import uuid; print(str(uuid.uuid4()).upper())')"
sleep 2
launch "$S" "$W/out3b" CEDRIC_TEST_SAVE_AFTER=4
for _ in $(seq 1 150); do grep -q '^saved:' "$W/out3b" && break; sleep 0.1; done
grep -q '^saved: ok=true dirty=false' "$W/out3b" && ok "3: relaunched, the restored edit saved with ⌘S" || bad "3: the relaunched save: $(grep '^saved:' "$W/out3b" || echo none)"
quit_app $pid
[ "$(sha_f "$F/big.txt")" = "$T3sha" ] && ok "3: the file now holds the edit" || bad "3: the saved file is not the edit"
left=$(ls -A "$W" | grep -E '^\.owlink-save-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$' | while read -r f; do [ -L "$W/$f" ] || echo "$f"; done | wc -l | tr -d ' ')
[ "$left" -ge 1 ] && ok "3: the killed save's partial file is still there after the next save ($left)" || bad "3: the partial .owlink-save-* file was deleted"
[ -e "$W/.owlink-save-not-a-uuid" ] && [ "$(ls -A "$W" | grep -E '^\.owlink-save-[0-9A-F-]{36}$' | while read -r f; do [ -L "$W/$f" ] && echo l; done)" = l ] \
    && ok "3: a look-alike name and a link with the name are left alone" || bad "3: a save removed a file beside it"
rm -f "$W/.owlink-save-not-a-uuid"; find "$W" -maxdepth 1 -name '.owlink-save-*' \( -type l -o -type f \) -delete

# 4. A crash (abort) instead of kill -9: an untitled tab and an edited
#    file, 1 s in (before the autosave interval would have saved them).
printf 'crash me\n' > "$F/crash.txt"
orig=$(sha_f "$F/crash.txt")
T4f=$(printf 'crash me\n edited before the crash')
T4u='untitled before the crash'
S=$(child s4)
launch "$S" "$W/out4" CEDRIC_OPEN="$F/crash.txt" CEDRIC_TEST_TYPE=" edited before the crash" CEDRIC_TEST_TYPE_UNTITLED="$T4u" CEDRIC_TEST_ABORT_AFTER=1
code=0; { wait $pid; } 2>/dev/null || code=$?
untrack $pid
[ $code = 134 ] && ok "4: the app crashed (SIGABRT, status 134)" || bad "4: exit status $code, want 134 (abort)"
expect_disk "4: the file on disk is untouched" "$F/crash.txt" "$orig"
dump "$S"
expect_tab "4: crash: the file's edit is back, unsaved, exact text, caret" "$F/crash.txt" "$T4f"
expect_tab "4: crash: the untitled tab is back, exact text, caret" - "$T4u"
expect_count "4" 2

# 5. Two windows, one tab a 30 MB file in large-document mode (lines of
#    40,000 characters): the session keeps its path, never its text.
python3 -I -c '
import sys
line = ("0123456789abcdefghij" * 2000)
open(sys.argv[1], "w").write("".join(line + "\n" for _ in range(750)))' "$F/huge.log"
hsha=$(sha_f "$F/huge.log"); hlen=$(stat -f %z "$F/huge.log")
printf 'small file\n' > "$F/small.txt"
S=$(child s5)
python3 -I - "$F" "$S" <<'PY'
import json, os, sys, uuid
w, d = sys.argv[1], sys.argv[2]
os.makedirs(d, exist_ok=True)
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
r=$(python3 -I - "$S" "$F/huge.log" <<'PY'
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
grep -E -q "^exact: win=[0-9]+ name=huge.log file=$F/huge.log dirty=false sha=$hsha len=$hlen sel=5,0 large=(size|longLine)" "$W/dump.txt" \
    && ok "5: the huge file reopened from disk, clean, exact, large mode, caret" || bad "5: huge file not restored as it is on disk"
small_sha=$(python3 -I -c 'import hashlib; print(hashlib.sha256(b"small file\nedited in window one\n").hexdigest())')
unt_sha=$(python3 -I -c 'import hashlib; print(hashlib.sha256(b"second window text\n").hexdigest())')
grep -E -q "^exact: win=[0-9]+ name=small.txt file=$F/small.txt dirty=true sha=$small_sha len=32 sel=3,0" "$W/dump.txt" \
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
printf 'will be deleted\n' > "$F/gone.txt"
printf 'will be renamed\n' > "$F/moved.txt"
T6g=$(printf 'will be deleted\n edit to a deleted file')
T6m=$(printf 'will be renamed\n edit to a renamed file')
S=$(child s6)
launch "$S" "$W/out6a" CEDRIC_OPEN="$F/gone.txt" CEDRIC_TEST_TYPE=" edit to a deleted file"
wait_holds "$S" "$F/gone.txt" "$(sha_s "$T6g")" 10 || bad "6: the first edit never reached the session store"
kill9 $pid
launch "$S" "$W/out6b" CEDRIC_OPEN="$F/moved.txt" CEDRIC_TEST_TYPE=" edit to a renamed file"
wait_holds "$S" "$F/moved.txt" "$(sha_s "$T6m")" 10 || bad "6: the second edit never reached the session store"
holds "$S" "$F/gone.txt" "$(sha_s "$T6g")" || bad "6: the first edit is no longer in the session store"
kill9 $pid
moved=$(sha_f "$F/moved.txt")
rm "$F/gone.txt"; mv "$F/moved.txt" "$F/moved-renamed.txt"
dump "$S"
expect_tab "6: deleted file: the edit is back, unsaved, exact, caret" "$F/gone.txt" "$T6g"
expect_tab "6: renamed file: the edit is back, unsaved, exact, caret" "$F/moved.txt" "$T6m"
grep -q "^notice: name=gone.txt missing=true disk=.*was deleted or moved" "$W/dump.txt" \
    && ok "6: deleted file: the tab says it was deleted or moved" || bad "6: no deleted/moved notice on gone.txt"
grep -q "^notice: name=moved.txt missing=true disk=.*was deleted or moved" "$W/dump.txt" \
    && ok "6: renamed file: the tab says it was deleted or moved" || bad "6: no deleted/moved notice on moved.txt"
expect_count "6" 2
expect_disk "6: the renamed file itself untouched" "$F/moved-renamed.txt" "$moved"
[ ! -e "$F/gone.txt" ] && [ ! -e "$F/moved.txt" ] && ok "6: nothing written back to the old paths" || bad "6: a file reappeared at an old path"

# 7. A truncated session.json: the app launches, keeps the bad file aside,
#    and every unsaved text comes back.
printf 'seven\n' > "$F/seven.txt"
orig=$(sha_f "$F/seven.txt")
T7f=$(printf 'seven\n edited before the store broke')
T7u='untitled before the store broke'
S=$(child s7)
launch "$S" "$W/out7" CEDRIC_OPEN="$F/seven.txt" CEDRIC_TEST_TYPE=" edited before the store broke" CEDRIC_TEST_TYPE_UNTITLED="$T7u"
wait_holds "$S" "$F/seven.txt" "$(sha_s "$T7f")" 10 && wait_holds "$S" - "$(sha_s "$T7u")" 10 || bad "7: the edits never reached the session store"
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
expect_disk "7: the file on disk is untouched" "$F/seven.txt" "$orig"
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

# 8. Killed between writing a new tab's buffer and committing the session
#    that names it, with an older, valid session in place.
T8a='in the committed session'
T8b='a new tab: its buffer written, the session naming it not yet'
S=$(child s8)
launch "$S" "$W/out8a" CEDRIC_TEST_TYPE_UNTITLED="$T8a"
wait_holds "$S" - "$(sha_s "$T8a")" 10 || bad "8: the first tab never reached the session store"
kill9 $pid
launch "$S" "$W/out8b" CEDRIC_TEST_TYPE_UNTITLED="$T8b" CEDRIC_TEST_HOLD_SESSION_COMMIT="$W/held8"
for _ in $(seq 1 150); do [ -s "$W/held8" ] && break; sleep 0.1; done
[ -s "$W/held8" ] && ok "8: a save stopped between the new buffer and the session" || bad "8: the save never reached the hold"
in_store=$(python3 -I - "$S" "$(sha_s "$T8b")" <<'PY'
import hashlib, os, sys
d, sha = sys.argv[1], sys.argv[2]
print(sum(1 for f in os.listdir(d) if f.endswith(".txt") and hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest() == sha))
PY
)
if [ "$in_store" = 1 ] && holds "$S" - "$(sha_s "$T8a")" && ! holds "$S" - "$(sha_s "$T8b")"; then
    ok "8: the new buffer is on disk, the older valid session doesn't name it"
else bad "8: store state at the kill: buffer files with the text $in_store, want 1, named by the old session: no"; fi
kill9 $pid
dump "$S"
expect_tab "8: the committed tab is back" - "$T8a"
expect_tab "8: the new tab's text is back (recovered), exact text, caret" - "$T8b"
expect_count "8" 2
# A normal launch (it saves and prunes), a quit, and again.
launch "$S" "$W/out8c"
sleep 4
quit_app $pid
dump "$S"
expect_tab "8: after a save, a prune and a relaunch: the committed tab" - "$T8a"
expect_tab "8: after a save, a prune and a relaunch: the new tab's text" - "$T8b"
expect_count "8 (after a save)" 2

# 9. Two quick changes in one turn, then a character every 0.1 s, killed
#    while the typing goes on: (a) after a quiet spell, 1 s in (the
#    leading save, a few ms after the first change, must not be cancelled
#    by the second); (b) starting 0.3 s after the launch's own save,
#    2.5 s in (the leading save comes 1.5 s after the last one, whatever
#    the typing). Typing after the last save may be lost, the first
#    changes never.
burst_case() { # NAME DELAY KILL_AFTER
    S=$(child s$1)
    launch "$S" "$W/out$1" CEDRIC_TEST_TYPE_BURST="two quick| changes" CEDRIC_TEST_TYPE_BURST_DELAY="$2"
    t0=$(typed_at "$W/out$1")
    sleep "$3"
    killed=$(now); kill9 $pid
    echo "crash-check: $1: killed $(python3 -I -c "print(int(($killed - $t0) * 1000))") ms after the two changes, still typing"
    dump "$S"
    r9=$(python3 -I - "$W/dump.txt" <<'PY'
import hashlib, re, sys
lines = [l for l in open(sys.argv[1]) if l.startswith("exact:")]
want = {hashlib.sha256(("two quick changes" + "." * k).encode()).hexdigest(): k for k in range(0, 40)}
for l in lines:
    m = re.search(r"file=- dirty=true sha=([0-9a-f]+) len=(\d+) sel=(\d+),0", l)
    if m and m.group(1) in want and m.group(2) == m.group(3):
        print("dots=%d" % want[m.group(1)]); break
else:
    print("none (%d tab(s))" % len(lines))
PY
)
    case "$r9" in dots=*) ok "$1: both quick changes are back (then ${r9#dots=} typed dot(s)), caret at the end" ;; *) bad "$1: the quick changes were not saved: $r9" ;; esac
    expect_count "$1" 1
}
burst_case 9a 2 1
burst_case 9b 0.3 2.5

# 10. Quit while every session write fails: the app must stay open.
T10='typed while the disk is full'
S=$(child s10)
launch "$S" "$W/out10" CEDRIC_TEST_TYPE_UNTITLED="$T10" CEDRIC_TEST_SESSION_WRITE_FAIL=1 CEDRIC_TEST_QUIT_SAVE_CHOICE=keep
typed_at "$W/out10" >/dev/null
sleep 1
osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate; ''" >/dev/null
sleep 3
if kill -0 $pid 2>/dev/null; then ok "10: the session couldn't be saved: quit refused, the app is still open"
else bad "10: the app quit although its session couldn't be saved"; fi
grep -q '^quit: session save failed, choice=keep' "$W/out10" && ok "10: the user was asked (Keep Owlink Open)" || bad "10: no failed-save question at quit"
kill9 $pid

# 11. A buffer that can't be read at launch: kept, said, never pruned.
S=$(child s11)
U11=$(python3 -I - "$S" <<'PY'
import json, os, sys, uuid
d = sys.argv[1]
os.makedirs(d, exist_ok=True)
i = str(uuid.uuid4()).upper()
open(os.path.join(d, i + ".txt"), "w").write("text that can't be read for now")
json.dump({"version": 1, "untitledCounter": 0, "windows": [{"tabs": [{"id": i, "untitledName": "Untitled", "hasBuffer": True,
    "encoding": "utf8", "lineEnding": "lf", "selectionLocation": 0, "selectionLength": 0, "topLine": 0}], "selectedTab": 0}]},
    open(os.path.join(d, "session.json"), "w"))
print(i)
PY
)
chmod 000 "$S/$U11.txt"
launch "$S" "$W/out11"
sleep 4
quit_app $pid
[ -e "$S/$U11.txt" ] && ok "11: the unreadable buffer survived a save and its prune" || bad "11: the unreadable buffer was deleted"
grep -q "\"$U11\"" "$S/session.json" && python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in s.get("heldBuffers", []) else 1)' "$S/session.json" "$U11" \
    && ok "11: the session names it as held" || bad "11: the session doesn't name the held buffer"
dump "$S"
grep -q "^notice: .*info=.*Owlink couldn’t read unsaved text from its last session" "$W/dump.txt" && ok "11: launch says it couldn't read it, and where it is kept" || bad "11: no notice about the unreadable buffer"
chmod 600 "$S/$U11.txt"
dump "$S"
expect_tab "11: readable again: the text is back, exact" - "text that can't be read for now" "name=Recovered"

# 12. Reopened, killed before the commit, past its retention next launch.
T12='closed with unsaved text, reopened, then killed'
S=$(child s12)
python3 -I - "$S" "$T12" <<'PY'
import json, os, sys, time, uuid
d, text = sys.argv[1], sys.argv[2]
i = str(uuid.uuid4()).upper()
open(os.path.join(d, i + ".txt"), "w").write(text)
# Closed 30 days less 25 s ago (seconds since 2001, as JSONEncoder writes dates).
closed = time.time() - 978307200 - 30 * 86400 + 25
n = len(text.encode("utf-16-le")) // 2
json.dump({"version": 1, "untitledCounter": 0, "windows": [], "closedTabs": [{"id": i, "untitledName": "Untitled", "hasBuffer": True,
    "encoding": "utf8", "lineEnding": "lf", "selectionLocation": n, "selectionLength": 0, "topLine": 0, "closed": closed}]},
    open(os.path.join(d, "session.json"), "w"))
PY
t12=$(date +%s)
launch "$S" "$W/out12" CEDRIC_TEST_REOPEN_CLOSED=1 CEDRIC_TEST_HOLD_SESSION_COMMIT="$W/held12"
for _ in $(seq 1 150); do [ -s "$W/held12" ] && break; sleep 0.1; done
[ -s "$W/held12" ] && ok "12: reopened, and the save that lists it open stopped before its commit" || bad "12: the save never reached the hold"
python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if len(s.get("closedTabs") or []) == 1 and not s["windows"] else 1)' "$S/session.json" \
    && ok "12: at the kill, the committed session still lists it as closed" || bad "12: the committed session already lists it open"
kill9 $pid
while [ $(( $(date +%s) - t12 )) -lt 27 ]; do sleep 0.5; done
dump "$S"
expect_tab "12: past its closing date's retention: back open, exact text, caret" - "$T12"
expect_count "12" 1
grep -q '^closed:' "$W/dump.txt" && bad "12: still on the closed list" || ok "12: no longer on the closed list"

# Whether an instance store in DIR (instances/*/) names an untitled tab
# with unsaved text whose SHA-256 is SHA, and has its buffer: prints it.
inst_holds() { # DIR SHA
    python3 -I - "$@" <<'PY'
import hashlib, json, os, sys
d, sha = sys.argv[1], sys.argv[2]
root = os.path.join(d, "instances")
for n in sorted(os.listdir(root)) if os.path.isdir(root) else []:
    i = os.path.join(root, n)
    try:
        s = json.load(open(os.path.join(i, "session.json")))
    except Exception:
        continue
    for w in s.get("windows", []):
        for t in w.get("tabs", []):
            if t.get("hasBuffer") and not t.get("path"):
                try:
                    b = open(os.path.join(i, t["id"] + ".txt"), "rb").read()
                except OSError:
                    continue
                if hashlib.sha256(b).hexdigest() == sha:
                    print(i); sys.exit(0)
sys.exit(1)
PY
}
wait_inst_holds() { # DIR SHA SECONDS
    local end=$(( $(date +%s) + $3 ))
    while [ "$(date +%s)" -le $end ]; do inst_holds "$1" "$2" >/dev/null && return 0; sleep 0.1; done
    return 1
}
# A buffer file directly in DIR with this SHA-256 (any name).
has_bytes() { # DIR SHA
    python3 -I - "$@" <<'PY'
import hashlib, os, sys
d, sha = sys.argv[1], sys.argv[2]
for f in os.listdir(d):
    p = os.path.join(d, f)
    if f.endswith(".txt") and os.path.isfile(p) and hashlib.sha256(open(p, "rb").read()).hexdigest() == sha: sys.exit(0)
sys.exit(1)
PY
}
# A store's files, and its buffers' SHA-256s (what "untouched" compares).
buffers_of() { ( cd "$1" && ls -A && for f in *.txt; do [ -f "$f" ] && echo "$f $(sha_f "$f")"; done ) 2>/dev/null || true; }

# 13. Two Owlinks on one session folder: a second is launched on it while
#     the first runs; the first backs up a new tab; then the second types
#     (its own saves follow) and quits. Before the lock its save
#     committed its own snapshot and pruned the first's buffer. Now it
#     restores, saves and prunes nothing there, and backs up its own text
#     in its own store: the first's text survives, the second's quit has
#     nothing to ask, and a kill of the first brings its text back.
T13a='the first Owlink: a new tab, backed up'
T13b='the second Owlink: never in this session'
S=$(child s13)
launch "$S" "$W/out13a" CEDRIC_TEST_TYPE_UNTITLED="$T13a" CEDRIC_TEST_TYPE_UNTITLED_DELAY=3
first=$pid
launch "$S" "$W/out13b" CEDRIC_TEST_TYPE_UNTITLED="$T13b" CEDRIC_TEST_TYPE_UNTITLED_DELAY=8 CEDRIC_TEST_QUIT_SAVE_CHOICE=quit
second=$pid
for _ in $(seq 1 100); do grep -q '^session: ' "$W/out13b" && break; sleep 0.05; done
grep -q "^session: own instance store: $S/instances/" "$W/out13b" \
    && ok "13: the second Owlink can't claim the session folder: it gets a store of its own in it" || bad "13: the second Owlink claimed the session folder ($(grep '^session: ' "$W/out13b" | head -1))"
typed_at "$W/out13a" >/dev/null
wait_holds "$S" - "$(sha_s "$T13a")" 10 && ok "13: the first Owlink backed up its new tab" || bad "13: the first's tab never reached the session store"
cp "$S/session.json" "$W/s13-before.json"
typed_at "$W/out13b" >/dev/null
sleep 3
holds "$S" - "$(sha_s "$T13a")" && ok "13: the first's buffer survives the second's typing and saves" || bad "13: the first's buffer is gone after the second's saves"
quit_app $second
grep -q '^quit: session save failed' "$W/out13b" \
    && bad "13: the second's quit asked: its text wasn't backed up" || ok "13: the second quit without asking"
inst_holds "$S" "$(sha_s "$T13b")" >/dev/null && ok "13: the second's text is in its own store" || bad "13: the second's text is nowhere on disk"
cmp -s "$S/session.json" "$W/s13-before.json" && ok "13: the second wrote no session" || bad "13: session.json changed while the second ran"
has_bytes "$S" "$(sha_s "$T13b")" && bad "13: the second wrote a buffer in the session folder" || ok "13: the second wrote no buffer in the session folder"
holds "$S" - "$(sha_s "$T13a")" && ok "13: the first's buffer survives the second's quit" || bad "13: the first's buffer is gone after the second's quit"
kill9 $first
dump "$S"
expect_tab "13: after a kill of the first: its tab back, exact text, caret" - "$T13a"
expect_count "13" 1

# 14. A second Owlink's own crash, and the next writer adopting its text.
#     Round 6 kept the second's text in memory only: the kill lost it.
T14a='the first Owlink, the session folder’s writer'
T14b='the second Owlink: typed, backed up, then killed ✓'
T14c='a third Owlink, still running'
S=$(child s14)
launch "$S" "$W/out14a" CEDRIC_TEST_TYPE_UNTITLED="$T14a"
first=$pid
typed_at "$W/out14a" >/dev/null
wait_holds "$S" - "$(sha_s "$T14a")" 10 || bad "14: the first's tab never reached the session store"
launch "$S" "$W/out14b" CEDRIC_TEST_TYPE_UNTITLED="$T14b"
second=$pid
for _ in $(seq 1 100); do grep -q '^session: ' "$W/out14b" && break; sleep 0.05; done
grep -q "^session: own instance store: $S/instances/" "$W/out14b" && ok "14: the second Owlink has a store of its own" || bad "14: the second Owlink has no store of its own"
typed_at "$W/out14b" >/dev/null
wait_inst_holds "$S" "$(sha_s "$T14b")" 10 && ok "14: the second's timed backup put its draft in its own store" || bad "14: the second's draft never reached a store"
kill9 $second
dead=$(inst_holds "$S" "$(sha_s "$T14b")" || true)
[ -n "$dead" ] && has_bytes "$dead" "$(sha_s "$T14b")" && ok "14: after kill -9 the second's draft is on disk in its store" || bad "14: the second's draft is gone after its kill"
has_bytes "$S" "$(sha_s "$T14b")" && bad "14: the second wrote in the session folder" || ok "14: nothing of the second's in the session folder itself"
launch "$S" "$W/out14c" CEDRIC_TEST_TYPE_UNTITLED="$T14c"
third=$pid
typed_at "$W/out14c" >/dev/null
wait_inst_holds "$S" "$(sha_s "$T14c")" 10 || bad "14: the third's draft never reached its store"
live=$(inst_holds "$S" "$(sha_s "$T14c")" || true)
sleep 2
live_before=$(buffers_of "$live")
quit_app $first
# The next writer, stopped at its first commit: the dead store's text is
# here already (journaled), and the dead store still there.
launch "$S" "$W/out14d" CEDRIC_TEST_HOLD_SESSION_COMMIT="$W/held14"
for _ in $(seq 1 150); do [ -s "$W/held14" ] && break; sleep 0.1; done
[ -s "$W/held14" ] && ok "14: the next writer's launch saves at once, held before its commit" || bad "14: the next writer never reached its commit"
has_bytes "$S" "$(sha_s "$T14b")" && ok "14: at that point the dead one's text is in the session folder" || bad "14: the dead one's text wasn't adopted before the commit"
[ -n "$dead" ] && [ -d "$dead" ] && has_bytes "$dead" "$(sha_s "$T14b")" && ok "14: and its store is still there (no commit yet)" || bad "14: the dead store went before a commit had its text"
kill9 $pid
launch "$S" "$W/out14e"
next=$pid
wait_holds "$S" - "$(sha_s "$T14b")" 15 && ok "14: relaunched: the session folder's commit has the dead one's text" || bad "14: the dead one's text never reached the session"
for _ in $(seq 1 100); do [ -d "$dead" ] || break; sleep 0.1; done
[ -n "$dead" ] && [ ! -e "$dead" ] && ok "14: the dead store is removed after that commit" || bad "14: the dead store is still there"
[ -n "$live" ] && [ -d "$live" ] && [ "$(buffers_of "$live")" = "$live_before" ] && ok "14: the live third's store is untouched" || bad "14: the live third's store changed"
quit_app $next
dump "$S"
expect_tab "14: the first's tab back, exact text, caret" - "$T14a"
expect_tab "14: the dead second's draft back, exact text, caret" - "$T14b"
expect_count "14" 2
kill9 $third

[ ! -e "$CANARY" ] && ok "the launches pruned this run's ReplaceUndo (its 30-day-old operation is gone), not the real one" \
    || bad "the 30-day-old operation in this run's ReplaceUndo is still there: the launches pruned some other folder"

[ $fail = 0 ] && echo "crash-check: all OK ($oks checks)" || echo "crash-check: FAILED ($oks OK)" >&2
exit $fail

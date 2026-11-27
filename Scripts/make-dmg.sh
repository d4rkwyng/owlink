#!/bin/bash
# Builds the drag-to-install disk image: a read-only compressed DMG whose
# window shows Owlink.app and an alias to /Applications (a symlink, as
# every drag-to-install DMG has), then mounts it and checks it. It puts in
# the very bundle it is given, copied with ditto (signature, stapled
# ticket, symlinks and attributes kept), and nothing else: no second
# build, nothing re-signed. Signing, notarizing and stapling the DMG
# itself is Scripts/release-dmg.sh's job (the release workflow runs that
# after this). Nothing here needs a secret or launches the app.
#
#   Scripts/make-dmg.sh [--volname NAME] [--no-layout] APP OUT.dmg
#   Scripts/make-dmg.sh --check DMG APP   only the checks below, on an existing DMG
#   Scripts/make-dmg.sh --self-test       builds a tiny ad-hoc-signed app and
#                                         checks the DMG it makes (and that
#                                         --check fails on a different app)
#
#   --volname NAME  the volume's name (default: Owlink)
#   --no-layout     skip the Finder window layout (icon positions,
#                   background-less 540x380 window); the DMG still has both
#                   items and works the same
#
# Layout: the image is first made read-write, mounted, and Finder is asked
# (osascript, under a 60 s alarm) to set an icon view with the app on the
# left and Applications on the right; then it is converted to UDZO. The
# layout is cosmetic: if Finder can't be scripted (no GUI session, an
# Automation prompt), or a volume of that name is already mounted, it is
# skipped with a warning, never a failure.
#
# Checks (also --check): the DMG mounts read-only at a private mount point
# (-nobrowse, -mountrandom); at its root are exactly NAME.app (one .app),
# "Applications" (a symlink to /Applications) and, at most, Finder's
# hidden .DS_Store/.background/.fseventsd/.Trashes; the .app is
# byte-for-byte the given bundle (diff -r, symlinks compared as links) and
# has the same code directory hash (codesign -d); a stapled ticket in the
# given bundle is still there (stapler validate, when the input validates).
# The image is detached on any exit.
set -euo pipefail

fail() { echo "make-dmg.sh: $*" >&2; exit 1; }
warn() { echo "make-dmg.sh: WARNING: $*" >&2; }
with_alarm() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

VOLNAME=Owlink
LAYOUT=1
MODE=make
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --volname) VOLNAME=$2; shift ;;
        --no-layout) LAYOUT=0 ;;
        --check) MODE=check ;;
        --self-test) MODE=selftest ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
        -*) fail "unknown option $1" ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

MOUNTS=()
TMPS=()
cleanup() {
    local rc=$? m t
    for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
        hdiutil detach -quiet "$m" 2>/dev/null || hdiutil detach -quiet -force "$m" 2>/dev/null || true
    done
    for t in ${TMPS[@]+"${TMPS[@]}"}; do rm -rf "$t"; done
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

newtmp() { local t; t=$(mktemp -d "${TMPDIR:-/tmp}/owlink-dmg.XXXXXX"); TMPS+=("$t"); echo "$t"; }

cdhash() { codesign -d -vvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }

# check DMG APP
check() {
    local dmg=$1 app=$2 name mnt entries e apps=0 link h1 h2
    [ -f "$dmg" ] || fail "--check: no DMG at $dmg"
    [ -d "$app" ] || fail "--check: no app at $app"
    name=$(basename "$app")
    # Under /tmp, not $TMPDIR: hdiutil may refuse a mount point on another
    # volume ("Permission denied").
    mnt=$(mktemp -d /tmp/owlink-dmg-mnt.XXXXXX)
    TMPS+=("$mnt")
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -noverify -mountpoint "$mnt" "$dmg" 2>/dev/null \
        || fail "$dmg does not mount"
    MOUNTS+=("$mnt")
    entries=$(cd "$mnt" && ls -A)
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        case "$e" in
            "$name") apps=$((apps + 1)) ;;
            Applications) ;;
            .DS_Store|.background|.fseventsd|.Trashes|.VolumeIcon.icns) ;;
            *.app) fail "$dmg has another app at its root: $e" ;;
            *) fail "$dmg has an unexpected item at its root: $e" ;;
        esac
    done <<<"$entries"
    [ $apps = 1 ] || fail "$dmg has no $name at its root (has: $(tr '\n' ' ' <<<"$entries"))"
    [ -L "$mnt/Applications" ] || fail "$dmg's Applications is not a symlink"
    link=$(readlink "$mnt/Applications")
    [ "$link" = /Applications ] || fail "$dmg's Applications points to $link, not /Applications"
    diff -r --no-dereference "$app" "$mnt/$name" >/dev/null 2>&1 \
        || fail "$dmg's $name differs from $app (diff -r): not the bundle that was put in"
    h1=$(cdhash "$app"); h2=$(cdhash "$mnt/$name")
    [ -n "$h1" ] || fail "$app has no code signature (codesign -d)"
    [ "$h1" = "$h2" ] || fail "$dmg's $name has CDHash ${h2:-none}, the bundle has $h1"
    if xcrun stapler validate -q "$app" >/dev/null 2>&1; then
        xcrun stapler validate -q "$mnt/$name" >/dev/null 2>&1 || fail "$app is stapled, $dmg's copy is not"
        echo "stapled ticket: present in the DMG's copy"
    fi
    hdiutil detach -quiet "$mnt" || hdiutil detach -quiet -force "$mnt"
    MOUNTS=()
    rmdir "$mnt" 2>/dev/null || true
    echo "DMG OK: $(basename "$dmg") holds $name (CDHash $h1, same files as $app) and Applications -> /Applications"
}

# Best-effort Finder layout of the read-write image mounted at /Volumes/$VOLNAME.
layout() { # mountpoint appname
    local mnt=$1 name=$2
    with_alarm 60 osascript - "$VOLNAME" "$name" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
    set volName to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 120, 740, 500}
            set opts to icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 128
            set text size of opts to 13
            set position of item appName of container window to {140, 170}
            set position of item "Applications" of container window to {400, 170}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT
}

make_dmg() { # APP OUT
    local app=$1 out=$2 name stage rw mnt
    [ -d "$app" ] && [ "${app%.app}" != "$app" ] || fail "not an .app bundle: $app"
    case "$out" in *.dmg) ;; *) fail "output must end in .dmg: $out" ;; esac
    name=$(basename "$app")
    stage=$(newtmp)
    mkdir "$stage/root"
    ditto "$app" "$stage/root/$name"
    ln -s /Applications "$stage/root/Applications"
    rw="$stage/rw.dmg"
    hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$stage/root" -fs HFS+ -format UDRW -ov "$rw"
    if [ $LAYOUT = 1 ]; then
        if [ -e "/Volumes/$VOLNAME" ]; then
            warn "/Volumes/$VOLNAME is already mounted: window layout skipped"
        else
            mnt="/Volumes/$VOLNAME"
            hdiutil attach -quiet -readwrite -noverify -noautoopen "$rw" || fail "can't mount $rw read-write"
            MOUNTS+=("$mnt")
            if layout "$mnt" "$name"; then
                sync
                [ -f "$mnt/.DS_Store" ] && echo "window layout: set" || warn "Finder made no .DS_Store: window layout not saved"
            else
                warn "Finder could not be scripted (no GUI session or no Automation access): window layout skipped"
            fi
            rm -rf "$mnt/.fseventsd" 2>/dev/null || true
            hdiutil detach -quiet "$mnt" || hdiutil detach -quiet -force "$mnt"
            MOUNTS=()
        fi
    fi
    rm -f "$out"
    hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$out"
    echo "made $out ($(stat -f '%z' "$out") bytes)"
}

selftest() {
    local t app other dmg
    t=$(newtmp)
    for n in Owlink Other; do
        app="$t/$n/Owlink.app"
        mkdir -p "$app/Contents/MacOS"
        cp /usr/bin/true "$app/Contents/MacOS/Cedric"
        plutil -create xml1 "$app/Contents/Info.plist"
        plutil -insert CFBundleIdentifier -string "invalid.owlink.dmg-selftest.$n" "$app/Contents/Info.plist"
        plutil -insert CFBundleExecutable -string Cedric "$app/Contents/Info.plist"
        plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
        ln -s MacOS/Cedric "$app/Contents/link"
        codesign --force --sign - "$app" 2>/dev/null
    done
    app="$t/Owlink/Owlink.app"; other="$t/Other/Owlink.app"; dmg="$t/out/Owlink-selftest.dmg"
    mkdir "$t/out"
    VOLNAME="Owlink selftest $$"
    LAYOUT=0
    make_dmg "$app" "$dmg"
    check "$dmg" "$app"
    # A separate process, so its own trap detaches what it mounted.
    if "$0" --check "$dmg" "$other" >/dev/null 2>&1; then fail "self-test: --check accepted a different app"; fi
    echo "self-test: --check refuses a different app"
    echo "make-dmg.sh self-test: OK"
}

case $MODE in
    selftest) selftest ;;
    check) [ ${#ARGS[@]} = 2 ] || fail "usage: --check DMG APP"; check "${ARGS[0]}" "${ARGS[1]}" ;;
    make)
        [ ${#ARGS[@]} = 2 ] || fail "usage: [--volname NAME] [--no-layout] APP OUT.dmg"
        make_dmg "${ARGS[0]}" "${ARGS[1]}"
        check "${ARGS[1]}" "${ARGS[0]}"
        ;;
esac

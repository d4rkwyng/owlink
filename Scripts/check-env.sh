# Sourced (not run) by every check script that launches Owlink:
#
#   . "$(dirname "$0")/check-env.sh"     (after `cd` to the checkout root)
#   cedric_isolate "$W"                  W: the script's own temp folder
#   cedric_require_check_build "$APP"    for a bundle, before its first launch
#
# cedric_isolate exports CEDRIC_REPLACE_UNDO_DIR=W/replace-undo for every
# launch that follows. A launch schedules ReplaceUndoStore.pruneAtLaunch()
# after the first frame whatever the session switches say; without this
# it enumerates the real ~/Library/Application Support/Cedric/ReplaceUndo
# and deletes Replace in Files' older undo copies, which can be a user's
# last copy of the text before a replace. A temp CEDRIC_SESSION_DIR alone
# does not stop that. W is removed by the script's own trap.
#
# cedric_require_check_build refuses a bundle that is not a check build,
# WITHOUT running it. A release build (bundle-app.sh --release) ignores
# CEDRIC_SESSION_DIR and CEDRIC_REPLACE_UNDO_DIR, so even one probe launch
# would rotate the real cli-token, restore and re-save the real session
# and prune the real ReplaceUndo. It decides from the bundle alone: the
# CedricCheckBuild Info.plist key bundle-app.sh writes for check builds
# only, and no embedded Sparkle.framework (only a release build embeds it).
#
# cedric_require_release_gate is for the release gates only (smoke-launch.sh,
# launch-check.sh --release), which launch a RELEASE binary as shipped. A
# release binary ignores both folder overrides, so every such launch uses
# the real ~/Library/Application Support/Cedric of the account it runs in:
# it rotates cli-token, and its first frame prunes ReplaceUndo (it honours
# CEDRIC_NO_RESTORE / CEDRIC_NO_SESSION_SAVE, so the gates pass those and
# Session is left alone). A temp extraction folder isolates nothing. Run
# the gates only in a disposable macOS user account or VM (a CI runner);
# they exit, having launched nothing, unless OWLINK_RELEASE_GATE=1, and
# only Scripts/release.sh sets it, on its own release path.
#
# Scripts/check-isolation-lint.sh (run by the test suite) fails if a
# script launches the app without sourcing this and calling both, if a
# release gate launches before cedric_require_release_gate, or if a script
# other than release.sh sets OWLINK_RELEASE_GATE.

cedric_isolate() { # WORKDIR
    [ -n "${1:-}" ] && [ -d "$1" ] || { echo "cedric_isolate: no work folder '${1:-}'" >&2; exit 1; }
    export CEDRIC_REPLACE_UNDO_DIR="$1/replace-undo"
    case "$CEDRIC_REPLACE_UNDO_DIR" in
        "$HOME/Library/"*) echo "cedric_isolate: refusing $CEDRIC_REPLACE_UNDO_DIR (inside ~/Library)" >&2; exit 1 ;;
    esac
}

# Prints why APP is not a check build, or nothing; status 0 = check build.
cedric_check_build_problem() { # APP
    local app=${1%/} plist key
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || { echo "$app has no Contents/Info.plist"; return 1; }
    key=$(plutil -extract CedricCheckBuild raw -o - "$plist" 2>/dev/null || true)
    [ "$key" = true ] || { echo "$app is not marked a check build (Info.plist CedricCheckBuild: ${key:-absent}); a release build ignores the test session and undo folders"; return 1; }
    [ ! -e "$app/Contents/Frameworks/Sparkle.framework" ] || { echo "$app embeds Sparkle.framework, which only a release build does"; return 1; }
    return 0
}

cedric_require_check_build() { # APP: exits 1, having run nothing, unless APP is a check build
    local why
    why=$(cedric_check_build_problem "$1") && return 0
    echo "$(basename "$0"): refusing to launch: $why. Build a check build with Scripts/bundle-app.sh (no --release)." >&2
    exit 1
}

# What a release-binary launch touches in the account that runs it.
CEDRIC_RELEASE_GATE_TOUCHES="~/Library/Application Support/Cedric/cli-token (rotated) and ~/Library/Application Support/Cedric/ReplaceUndo (older Replace in Files undo copies pruned), and the account's crash reports and Launch Services registration"

cedric_require_release_gate() { # exits 1, having launched nothing, unless OWLINK_RELEASE_GATE=1
    if [ "${OWLINK_RELEASE_GATE:-}" != 1 ]; then
        echo "$(basename "$0"): refusing to run a release gate: it launches a release binary, which ignores the test folders and uses $CEDRIC_RELEASE_GATE_TOUCHES. Run it only in a disposable macOS user account or VM, with OWLINK_RELEASE_GATE=1 (Scripts/release.sh sets it on its own release path)." >&2
        exit 1
    fi
    echo "WARNING: $(basename "$0") launches a release binary as shipped. It touches $CEDRIC_RELEASE_GATE_TOUCHES of $(id -un) ($HOME). This belongs in a disposable macOS user account or VM." >&2
}

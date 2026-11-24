#!/bin/bash
# ios-gate.sh — the iOS test gate: build Owlink for the simulator, run
# OwlinkSnapshotTests and OwlinkUITests on three dedicated simulators
# (gate-iphone, gate-ipad-mini, gate-ipad-pro-13), save screenshots of the
# main screens for this build, pixel-diff them against the previous build's,
# and print a pass/fail summary with xcodebuild's own result lines.
#
# Usage:  Scripts/ios-gate.sh            (from anywhere in the repo)
#   GATE_DEVICES="gate-iphone gate-ipad-mini"   only these gate devices
#   GATE_SERIAL=1                 devices one after another (default: in parallel)
#   GATE_DIFF_THRESHOLD=2.0       percent of differing pixels that counts as a change
#   GATE_DIFF_STRICT=1            a screenshot change above the threshold fails the gate too
#   GATE_SHOTS=~/Orchestrator/scratch/owlink-ios-gate/shots   where build folders go
# Exit status: 0 when every test passed (or failed only as a named known
# failure), 1 on any unexpected test failure or a build/run error.
#
# Safe to re-run: it reuses (or creates) only the gate-* simulators, never
# shuts anything down, never calls xcode-select, and writes each run to a
# new /tmp/ios-gate-run-<time> folder (derived data: /tmp/ios-gate-dd).
set -u

DEV=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR=$DEV
unset ANTHROPIC_API_KEY XAI_API_KEY
REPO=$(cd "$(dirname "$0")/.." && pwd)
PROJECT=$REPO/ios/Owlink.xcodeproj
DD=/tmp/ios-gate-dd
RUN=/tmp/ios-gate-run-$(date +%Y%m%d-%H%M%S)
SHOTS=${GATE_SHOTS:-$HOME/Orchestrator/scratch/owlink-ios-gate/shots}
THRESHOLD=${GATE_DIFF_THRESHOLD:-2.0}
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-2
TARGETS="OwlinkSnapshotTests OwlinkUITests"
# Tests allowed to fail, named in the summary (none: the four UI tests that
# failed at b60886f pass now).
KNOWN_FAILURES=""
mkdir -p "$RUN"

device_type() {
    case $1 in
        gate-iphone) echo com.apple.CoreSimulator.SimDeviceType.iPhone-17 ;;
        gate-ipad-mini) echo com.apple.CoreSimulator.SimDeviceType.iPad-mini-A20-Pro ;;
        gate-ipad-pro-13) echo com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB ;;
    esac
}

# The UDID of a gate device, created if it isn't there (never any other device).
gate_udid() {
    local name=$1 udid
    udid=$(xcrun simctl list devices | sed -n "s/^ *$name (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1)
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl create "$name" "$(device_type "$name")" "$RUNTIME") || return 1
        echo "created $name $udid" >&2
    fi
    echo "$udid"
}

DEVICES=${GATE_DEVICES:-gate-iphone gate-ipad-mini gate-ipad-pro-13}
for d in $DEVICES; do
    [ -n "$(device_type "$d")" ] || { echo "not a gate device: $d" >&2; exit 2; }
done

VERSION=$(sed -n 's/.*MARKETING_VERSION = "\{0,1\}\([0-9.]*\)"\{0,1\};/\1/p' "$PROJECT/project.pbxproj" | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)
SHA=$(git -C "$REPO" rev-parse --short HEAD)
LABEL=$VERSION-$BUILD-$SHA
echo "== iOS gate: Owlink $VERSION ($BUILD) at $SHA; run folder $RUN"

# 1. Build once for every simulator.
echo "== build (build-for-testing)"
if ! xcodebuild -project "$PROJECT" -scheme Owlink -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DD" build-for-testing > "$RUN/build.log" 2>&1; then
    grep -E "error:" "$RUN/build.log" | head -20
    echo "GATE FAIL: the build failed (see $RUN/build.log)"
    exit 1
fi
grep -E "\*\* TEST BUILD SUCCEEDED \*\*" "$RUN/build.log"

# 2. Tests, per device and target.
run_device() {
    local name=$1 udid=$2 t
    # A steady status bar for the screenshots (the gate device only).
    xcrun simctl boot "$udid" > /dev/null 2>&1
    xcrun simctl bootstatus "$udid" > /dev/null 2>&1
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
        --wifiBars 3 --cellularBars 4 > /dev/null 2>&1
    for t in $TARGETS; do
        xcodebuild -project "$PROJECT" -scheme Owlink -destination "platform=iOS Simulator,id=$udid" \
            -derivedDataPath "$DD" -resultBundlePath "$RUN/$name-$t.xcresult" \
            test-without-building -only-testing:"$t" > "$RUN/$name-$t.log" 2>&1
        echo $? > "$RUN/$name-$t.exit"
    done
}

for d in $DEVICES; do
    udid=$(gate_udid "$d") || { echo "GATE FAIL: couldn't find or create $d"; exit 1; }
    echo "== $d ($udid): $TARGETS"
    if [ -n "${GATE_SERIAL:-}" ]; then run_device "$d" "$udid"; else run_device "$d" "$udid" & fi
done
wait

# 3. Screenshots of the main screens (testGateScreenshots' attachments).
OUT=$SHOTS/$LABEL
mkdir -p "$OUT"
for d in $DEVICES; do
    bundle=$RUN/$d-OwlinkUITests.xcresult
    [ -d "$bundle" ] || continue
    att=$RUN/$d-attachments
    mkdir -p "$att"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$att" \
        --test-id "OwlinkUITests/testGateScreenshots()" > /dev/null 2>&1
    python3 -I - "$att" "$OUT" "$d" <<'EOF'
import json, os, re, shutil, sys
att, out, device = sys.argv[1:4]
try:
    manifest = json.load(open(os.path.join(att, "manifest.json")))
except OSError:
    sys.exit(0)
for test in manifest:
    for a in test.get("attachments", []):
        m = re.match(r"gate-([A-Za-z0-9-]+?)(_\d+_[0-9A-F-]+)?\.png$", a.get("suggestedHumanReadableName", ""))
        if m:
            shutil.copyfile(os.path.join(att, a["exportedFileName"]), os.path.join(out, f"{device}-{m.group(1)}.png"))
EOF
done
SHOT_COUNT=$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
echo "== screenshots: $SHOT_COUNT in $OUT"

# 4. Pixel diff against the previous build's folder (the newest other one).
DIFF_RESULT="no previous build"
PREV=$(ls -td "$SHOTS"/*/ 2>/dev/null | sed 's#/$##' | grep -vx "$OUT" | head -1)
if [ -z "$PREV" ]; then
    echo "== pixel diff: no previous build's screenshots in $SHOTS: this run's are the baseline"
    DIFF_RESULT="baseline saved (no previous build)"
else
    echo "== pixel diff: $(basename "$PREV") -> $LABEL (threshold $THRESHOLD%)"
    if python3 -I "$REPO/Scripts/ios-gate-pixdiff.py" "$PREV" "$OUT" "$THRESHOLD"; then
        DIFF_RESULT="PASS (nothing above $THRESHOLD%)"
    else
        DIFF_RESULT="FAIL (images above $THRESHOLD%: see the list above)"
    fi
fi

# 5. Summary: xcodebuild's own lines, failures named.
echo
echo "== summary: Owlink $VERSION ($BUILD) at $SHA"
UNEXPECTED=0
for d in $DEVICES; do
    for t in $TARGETS; do
        log=$RUN/$d-$t.log
        line=$(grep -E "^[[:space:]]*Executed [0-9]+ tests?, with" "$log" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')
        code=$(cat "$RUN/$d-$t.exit" 2>/dev/null || echo "?")
        printf '%-17s %-20s %s\n' "$d" "$t" "${line:-no result line (exit $code; see $log)}"
        failed=$(grep -E "^Test Case '-\[[^]]+\]' failed" "$log" 2>/dev/null | sed -E "s/^Test Case '-\[[^ ]+ ([^]]+)\]'.*/\1/" | sort -u)
        for f in $failed; do
            if echo " $KNOWN_FAILURES " | grep -q " $f "; then
                echo "    known failure: $f"
            else
                echo "    FAILED: $f"
                grep -E "error: -\[[^ ]+ $f\]" "$log" | head -2 | sed 's/^/      /'
                UNEXPECTED=1
            fi
        done
        if [ -z "$line" ] || { [ "$code" != 0 ] && [ -z "$failed" ]; }; then
            echo "    run error (exit $code), see $log"
            UNEXPECTED=1
        fi
        skipped=$(grep -E "^Test Case '-\[[^]]+\]' skipped" "$log" 2>/dev/null | sed -E "s/^Test Case '-\[[^ ]+ ([^]]+)\]'.*/\1/" | sort -u | tr '\n' ' ')
        [ -n "$skipped" ] && echo "    skipped: $skipped"
    done
done
echo "screenshots: $OUT ($SHOT_COUNT)"
echo "pixel diff: $DIFF_RESULT"
if [ "$UNEXPECTED" != 0 ]; then
    echo "GATE FAIL: unexpected test failures (logs and result bundles in $RUN)"
    exit 1
fi
if [ -n "${GATE_DIFF_STRICT:-}" ] && [[ $DIFF_RESULT == FAIL* ]]; then
    echo "GATE FAIL: screenshots changed above $THRESHOLD% (GATE_DIFF_STRICT)"
    exit 1
fi
echo "GATE PASS"

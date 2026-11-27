#!/bin/bash
# Static lint: every script that launches Owlink keeps the launch off the
# user's data (Scripts/check-env.sh says why). Run by the test suite
# (CheckIsolationLintTests); nothing is built or launched.
#
#   Scripts/check-isolation-lint.sh [SCRIPT ...]     default: Scripts/*.sh
#
# A launch is a command line (continuations joined, comments dropped) that
# runs a variable assigned from Contents/MacOS/Cedric or from the SwiftPM
# CedricApp binary, other than as the argument of an inspecting tool
# ([ -x ], otool, lipo, strings, codesign, ...). A script with a launch must:
#   1. source check-env.sh and call cedric_isolate before its first launch
#      (CEDRIC_REPLACE_UNDO_DIR for every launch);
#   2. set CEDRIC_SESSION_DIR;
#   3. if it launches a bundle (Contents/MacOS/Cedric), call
#      cedric_require_check_build before its first launch, so a release
#      build is refused before it runs;
#   4. on a launch that strips the environment (env -i, ENV_CLEAN, or
#      -u CEDRIC_REPLACE_UNDO_DIR / -u CEDRIC_SESSION_DIR), set both
#      variables on that same command.
# The release gate (launch-check.sh, smoke-launch.sh) launches release
# builds as shipped; a script marked "# isolation-lint: release-gate" is
# held only to 4, and a launch there meant to run as a user does carries
# "# isolation-lint: real-launch <why>" on the line above it instead.
# The lint lists every launch it allowed that way.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ $# = 0 ]; then set -- Scripts/*.sh; fi
exec python3 -I - "$@" <<'PY'
import re, sys

# Commands that take the executable as an argument without running it.
INSPECT = {"otool", "lipo", "strings", "codesign", "install_name_tool", "nm", "file", "shasum", "dirname", "basename",
           "xattr", "spctl", "stapler", "ls", "stat", "du", "cp", "ditto", "rm", "mv", "echo", "printf", "grep", "test", "[", "[["}
SKIP = {"Scripts/check-env.sh", "Scripts/check-isolation-lint.sh"}

def logical_lines(text):
    """(first line number, joined command, marker on the line above)"""
    out, buf, start, marker, prev_marker = [], "", 0, None, None
    for n, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if s.startswith("#"):
            m = re.match(r'#\s*isolation-lint:\s*real-launch\b(.*)', s)
            prev_marker = m.group(1).strip() if m else None
            continue
        if not buf:
            start, marker, prev_marker = n, prev_marker, None
        code = re.sub(r'(^|\s)#.*$', '', raw) if "'" not in raw and '"' not in raw else raw
        if code.rstrip().endswith("\\"):
            buf += code.rstrip()[:-1] + " "
            continue
        buf += code
        out.append((start, buf, marker))
        buf = ""
    if buf:
        out.append((start, buf, marker))
    return out

problems, allowed = [], []
for path in sys.argv[1:]:
    if path in SKIP or not path.endswith(".sh"):
        continue
    text = open(path, encoding="utf-8").read()
    lines = logical_lines(text)
    exe_vars, bundle_vars = set(), set()
    for _, l, _ in lines:
        m = re.match(r'\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*$', l)
        if m and re.search(r'(Contents/MacOS/Cedric|/CedricApp|\)/Cedric)"?$', m.group(2)):
            exe_vars.add(m.group(1))
            if "CedricApp" not in m.group(2):
                bundle_vars.add(m.group(1))
    if not exe_vars:
        continue
    launches = []
    for n, l, marker in lines:
        for v in exe_vars:
            for m in re.finditer(r'"\$\{?%s\}?"' % v, l):
                before = l[:m.start()]
                seg = re.split(r'\|\||&&|[|;]|[$<]\(|`', before)[-1]
                if re.search(r'^\s*\w+=("[^"]*"|\S*)\s*$', seg) or re.search(r'\bfor \w+ in\b', seg) \
                        or (seg.split() or [""])[0] in INSPECT or re.search(r'(^|\s)(\[\[?|test)\s', seg):
                    continue
                launches.append((n, l, marker, v))
    if not launches:
        continue
    first = min(n for n, *_ in launches)
    gate = re.search(r'^#\s*isolation-lint:\s*release-gate\b', text, re.M) is not None
    def line_of(pat):
        for n, l, _ in lines:
            if re.search(pat, l):
                return n
        return None
    src = line_of(r'(^|\s)(\.|source)\s+\S*check-env\.sh')
    iso = line_of(r'(^|[\s;&|])cedric_isolate\s')
    req = line_of(r'(^|[\s;&|])cedric_require_check_build\s')
    if not gate and (src is None or src > first):
        problems.append(f"{path}:{first}: launches the app without sourcing Scripts/check-env.sh first")
    if not gate and (iso is None or iso > first):
        problems.append(f"{path}:{first}: launches the app before cedric_isolate (no CEDRIC_REPLACE_UNDO_DIR: the launch prunes the real ReplaceUndo)")
    if not gate and "CEDRIC_SESSION_DIR" not in text:
        problems.append(f"{path}:{first}: launches the app without CEDRIC_SESSION_DIR")
    if not gate and any(v in bundle_vars for *_, v in launches) and (req is None or req > first):
        problems.append(f"{path}:{first}: launches a bundle without cedric_require_check_build first (a release build would use the real session, token and ReplaceUndo)")
    for n, l, marker, v in launches:
        strips = re.search(r'\benv\s+-i\b|ENV_CLEAN|-u\s+CEDRIC_(REPLACE_UNDO_DIR|SESSION_DIR)\b', l)
        if not strips:
            continue
        if marker is not None:
            allowed.append(f"{path}:{n}: real-launch: {marker or '(no reason given)'}")
            continue
        if not (re.search(r'CEDRIC_SESSION_DIR=', l) and re.search(r'CEDRIC_REPLACE_UNDO_DIR=', l)):
            problems.append(f"{path}:{n}: a launch that strips the environment must set CEDRIC_SESSION_DIR= and CEDRIC_REPLACE_UNDO_DIR= on the same command")

for a in allowed:
    print("check-isolation-lint: allowed", a)
for p in problems:
    print("check-isolation-lint: FAIL", p, file=sys.stderr)
if problems:
    print(f"check-isolation-lint: FAILED ({len(problems)} problem(s))", file=sys.stderr)
    sys.exit(1)
print("check-isolation-lint: OK")
PY

#!/bin/bash
# Static lint: every script that launches Owlink keeps the launch off the
# user's data (Scripts/check-env.sh says why). Run by the test suite
# (CheckIsolationLintTests); nothing is built or launched.
#
#   Scripts/check-isolation-lint.sh [SCRIPT ...]   default: Scripts/*.sh Scripts/*.swift
#
# A launch is a command line (continuations joined, comments dropped) that
# runs a variable assigned from Contents/MacOS/Cedric or from the SwiftPM
# CedricApp binary, other than as the argument of an inspecting tool
# ([ -x ], otool, lipo, strings, codesign, ...). A shell script with a
# launch must:
#   1. source check-env.sh and call cedric_isolate before its first launch
#      (CEDRIC_REPLACE_UNDO_DIR for every launch);
#   2. set CEDRIC_SESSION_DIR= in code (a comment does not count);
#   3. for EACH bundle it launches (each Contents/MacOS/Cedric variable,
#      traced back to its .app variable or path), call
#      cedric_require_check_build on that same bundle before that
#      variable's first launch, so a release build is refused before it
#      runs (a guard for one bundle does not cover another);
#   4. on a launch that strips the environment (env -i, ENV_CLEAN, or
#      -u CEDRIC_REPLACE_UNDO_DIR / -u CEDRIC_SESSION_DIR), set both
#      variables on that same command.
# A release gate (smoke-launch.sh) launches a release build as shipped and
# is marked "# isolation-lint: release-gate". It is held to 4 and must call
# cedric_require_release_gate (the OWLINK_RELEASE_GATE=1 opt-in) before
# its first launch. Only there may a launch carry
# "# isolation-lint: real-launch <why>" on the line above it, which waives
# 4 for that launch; the lint lists every launch it allowed that way.
# Anywhere else the marker is itself a failure.
# Also, in every shell script:
#   5. only Scripts/release.sh may set OWLINK_RELEASE_GATE=, and there only
#      on the command that runs launch-check.sh --release;
#   6. no open(1) of Owlink (an .app, an app variable, -a/-b, a cedric://
#      URL): Launch Services takes no per-launch environment from the
#      script, so the launch would use the real session and folders;
#   7. a `swift FILE.swift` launcher is linted as below.
# A Swift script that launches an app (NSWorkspace openApplication /
# launchApplication / open, or a Contents/MacOS path) must, in code, read
# the CedricCheckBuild marker and set CEDRIC_SESSION_DIR and
# CEDRIC_REPLACE_UNDO_DIR.
#
# This is a regression check for the known shell forms, not a proof: it
# reads text in order, so conditional setup, helper functions called
# later, other launchers (a Process inside the app, python, osascript) and
# variables it cannot trace escape it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ $# = 0 ]; then set -- Scripts/*.sh Scripts/*.swift; fi
exec python3 -I - "$@" <<'PY'
import os, re, sys

# Commands that take the executable as an argument without running it.
INSPECT = {"otool", "lipo", "strings", "codesign", "install_name_tool", "nm", "file", "shasum", "dirname", "basename",
           "xattr", "spctl", "stapler", "ls", "stat", "du", "cp", "ditto", "rm", "mv", "echo", "printf", "grep", "test", "[", "[["}
SKIP = {"Scripts/check-env.sh", "Scripts/check-isolation-lint.sh"}
MARK = re.compile(r'#\s*isolation-lint:\s*real-launch\b(.*)')

def strip_comment(raw):
    """The line without a trailing # comment (one outside quotes, after a blank or at the start)."""
    q, esc = None, False
    for i, c in enumerate(raw):
        if esc:
            esc = False
        elif c == "\\" and q != "'":
            esc = True
        elif q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or raw[i - 1] in " \t"):
            return raw[:i]
    return raw

def logical_lines(text):
    """(first line number, joined command, marker on the line above)"""
    out, buf, start, marker, prev_marker = [], "", 0, None, None
    for n, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if s.startswith("#"):
            m = MARK.match(s)
            prev_marker = m.group(1).strip() if m else None
            continue
        if not buf:
            start, marker, prev_marker = n, prev_marker, None
        code = strip_comment(raw)
        if code.rstrip().endswith("\\"):
            buf += code.rstrip()[:-1] + " "
            continue
        buf += code
        out.append((start, buf, marker))
        buf = ""
    if buf:
        out.append((start, buf, marker))
    return out

def norm(arg):
    """A bundle as written: "$APP", ${APP%/}, 'dist/Owlink.app' -> $APP / dist/Owlink.app"""
    a = arg.strip().strip('"\'')
    m = re.fullmatch(r'\$\{?([A-Za-z_]\w*|\d)(?:[%#:][^}]*)?\}?', a)
    return "$" + m.group(1) if m else a.rstrip("/")

def segments(l):
    return re.split(r'\|\||&&|[|;]|[$<]\(|`', l)

def swift_problems(path):
    """Why a Swift script that launches an app is not isolated (empty: fine or no launch)."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return []
    code = "\n".join(re.sub(r'//.*$', '', l) for l in text.splitlines())
    if not re.search(r'openApplication\s*\(|launchApplication\s*\(|NSWorkspace\.shared\.open\s*\(|Contents/MacOS', code):
        return []
    why = []
    if "CedricCheckBuild" not in code:
        why.append("does not check the CedricCheckBuild marker before launching (a release build would use the real session, token and ReplaceUndo)")
    for v in ("CEDRIC_SESSION_DIR", "CEDRIC_REPLACE_UNDO_DIR"):
        if v not in code:
            why.append(f"launches without setting {v}")
    return why

problems, allowed = [], []
for path in sys.argv[1:]:
    if path in SKIP:
        continue
    if path.endswith(".swift"):
        for w in swift_problems(path):
            problems.append(f"{path}: a Swift launcher {w}")
        continue
    if not path.endswith(".sh"):
        continue
    text = open(path, encoding="utf-8").read()
    lines = logical_lines(text)
    gate = re.search(r'^#\s*isolation-lint:\s*release-gate\b', text, re.M) is not None
    is_release = os.path.basename(path) == "release.sh"

    # 5. The release-gate opt-in.
    for n, l, _ in lines:
        if re.search(r'(^|[\s;&|(])(export\s+)?OWLINK_RELEASE_GATE=', l):
            if not is_release:
                problems.append(f"{path}:{n}: sets OWLINK_RELEASE_GATE (only Scripts/release.sh may, on its release path: a release gate touches the real cli-token and ReplaceUndo)")
            elif not re.search(r'launch-check\.sh\s+--release\b', l):
                problems.append(f"{path}:{n}: sets OWLINK_RELEASE_GATE other than on the launch-check.sh --release command")

    # Variables naming a bundle (.app) or a cedric:// URL, for open(1).
    app_vars = set()
    for _, l, _ in lines:
        m = re.match(r'\s*(?:local\s+|export\s+)?([A-Za-z_]\w*)=(.*?)\s*$', l)
        if m and re.search(r'\.app\b|cedric://', m.group(2)):
            app_vars.add(m.group(1))
    # 6. open(1) of Owlink; 7. Swift launchers.
    here = os.path.dirname(path)
    for n, l, _ in lines:
        for seg in segments(l):
            w = seg.split()
            while w and (re.fullmatch(r'\w+=\S*', w[0]) or w[0] in ("exec", "command", "env", "nice", "nohup")):
                w = w[1:]
            if not w:
                continue
            args = " ".join(w[1:])
            if w[0] in ("open", "/usr/bin/open"):
                uses_var = any(re.search(r'\$\{?%s\b' % v, args) for v in app_vars)
                if re.search(r'\.app\b|cedric://|(^|\s)-[a-zA-Z]*[ab]\b', args) or uses_var or re.search(r'\$\{?APP\b', args):
                    problems.append(f"{path}:{n}: launches Owlink with open(1): Launch Services passes no per-launch environment, so it would use the real session, token and ReplaceUndo (run the bundle's binary instead)")
            if w[0] == "swift" and len(w) > 1 and w[1].strip('"\'').endswith(".swift"):
                f = w[1].strip('"\'')
                f = re.sub(r'^\$\{?HERE\}?/', here + "/", f)
                cands = [f, os.path.join(here, os.path.basename(f))]
                hit = next((c for c in cands if os.path.isfile(c)), None)
                for why in (swift_problems(hit) if hit else []):
                    problems.append(f"{path}:{n}: runs a Swift launcher ({f}) that {why}")

    for n, l, marker in lines:
        if marker is not None and not gate:
            problems.append(f"{path}:{n}: an isolation-lint real-launch marker outside a release gate (a check launch must set both folders itself)")

    # Launch variables, and the bundle each launches.
    exe_vars, bundle_of = set(), {}
    for _, l, _ in lines:
        m = re.match(r'\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*$', l)
        if not (m and re.search(r'(Contents/MacOS/Cedric|/CedricApp|\)/Cedric)"?$', m.group(2))):
            continue
        name, val = m.group(1), m.group(2)
        exe_vars.add(name)
        if "CedricApp" in val:
            continue
        b = re.search(r'\$\{?([A-Za-z_]\w*|\d)(?:[%#:][^}]*)?\}?/Contents/MacOS/Cedric', val)
        if b:
            bundle_of[name] = "$" + b.group(1)
            continue
        ref = next((r for r in re.findall(r'\$\{?([A-Za-z_]\w*)', val) if r in bundle_of), None)
        if ref:
            bundle_of[name] = bundle_of[ref]
        else:
            bundle_of[name] = norm(re.sub(r'/Contents/MacOS/Cedric"?$', '', val))
    if not exe_vars:
        continue
    launches = []
    for n, l, marker in lines:
        for v in exe_vars:
            for m in re.finditer(r'"\$\{?%s\}?"' % v, l):
                seg = segments(l[:m.start()])[-1]
                if re.search(r'^\s*\w+=("[^"]*"|\S*)\s*$', seg) or re.search(r'\bfor \w+ in\b', seg) \
                        or (seg.split() or [""])[0] in INSPECT or re.search(r'(^|\s)(\[\[?|test)\s', seg):
                    continue
                launches.append((n, l, marker, v))
    if not launches:
        continue
    first = min(n for n, *_ in launches)
    def line_of(pat):
        for n, l, _ in lines:
            if re.search(pat, l):
                return n
        return None
    src = line_of(r'(^|\s)(\.|source)\s+\S*check-env\.sh')
    iso = line_of(r'(^|[\s;&|])cedric_isolate\s')
    rel = line_of(r'(^|[\s;&|])cedric_require_release_gate\b')
    guards = {}
    for n, l, _ in lines:
        for g in re.finditer(r'(?:^|[\s;&|])cedric_require_check_build\s+("[^"]*"|\'[^\']*\'|\S+)', l):
            guards.setdefault(norm(g.group(1)), n)
    if gate and (rel is None or rel > first):
        problems.append(f"{path}:{first}: a release gate launches before cedric_require_release_gate (it must not run without OWLINK_RELEASE_GATE=1)")
    if not gate and (src is None or src > first):
        problems.append(f"{path}:{first}: launches the app without sourcing Scripts/check-env.sh first")
    if not gate and (iso is None or iso > first):
        problems.append(f"{path}:{first}: launches the app before cedric_isolate (no CEDRIC_REPLACE_UNDO_DIR: the launch prunes the real ReplaceUndo)")
    if not gate and not any(re.search(r'(^|[\s;&|(])CEDRIC_SESSION_DIR=', l) for _, l, _ in lines):
        problems.append(f"{path}:{first}: launches the app without CEDRIC_SESSION_DIR")
    if not gate:
        for v in sorted({v for *_, v in launches if v in bundle_of}):
            vfirst = min(n for n, _, _, lv in launches if lv == v)
            g = guards.get(bundle_of[v])
            if g is None or g > vfirst:
                problems.append(f"{path}:{vfirst}: launches a bundle ({bundle_of[v]}) without cedric_require_check_build {bundle_of[v]} first (a release build would use the real session, token and ReplaceUndo)")
    for n, l, marker, v in launches:
        strips = re.search(r'\benv\s+-i\b|ENV_CLEAN|-u\s+CEDRIC_(REPLACE_UNDO_DIR|SESSION_DIR)\b', l)
        if not strips:
            continue
        if marker is not None and gate:
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

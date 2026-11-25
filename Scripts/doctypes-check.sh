#!/bin/bash
# Checks a built Owlink.app's Info.plist against Resources/document-types.txt:
# one CFBundleDocumentTypes entry per row with its content types, its icon
# (CFBundleTypeIconFile, and the .icns in Contents/Resources), role Editor,
# the row's LSHandlerRank, Alternate labelled rows exactly MD, JSON and
# YAML, Alternate claims that are exactly 0.2.x's (once each), no claim in
# two rows but the five 0.5.3 also had there (see the header of
# Resources/document-types.txt), and an
# imported type declaration exactly for the rows that have one. Also that
# nothing asks macOS to compose icons instead (no
# CFBundleTypeIconSystemGenerated, no UTTypeIcons) and that every
# other document type (PDF, images, Office) is Alternate.
#
#   Scripts/doctypes-check.sh [APP]     default "dist/Owlink.app"
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-dist/Owlink.app}
PL="$APP/Contents/Info.plist"
[ -f "$PL" ] || { echo "no $PL: run Scripts/bundle-app.sh first" >&2; exit 1; }
plutil -lint "$PL" >/dev/null
TMP=$(mktemp -t owlink-plist)
trap 'rm -f "$TMP"' EXIT
plutil -convert xml1 -o "$TMP" "$PL"
/usr/bin/python3 - "$TMP" "$APP/Contents/Resources" Resources/document-types.txt <<'PY'
import plistlib, sys, os
pl = plistlib.load(open(sys.argv[1], 'rb'))
res, src = sys.argv[2], sys.argv[3]
fails = 0
def check(ok, what):
    global fails
    print(f"doctypes: {'PASS' if ok else 'FAIL'} {what}")
    fails += 0 if ok else 1
rows = []
for line in open(src):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    f = line.split('|')
    if len(f) != 6:
        check(False, f"row has 6 fields: {line!r}")
        continue
    label, icon, name, utis, decl, rank = f
    rows.append((label, icon, name, utis.split(','), decl, rank))
# bundle-app.sh's reader (Scripts/doc-types-rows.sh) reads the same rows,
# also from a copy with whitespace after each row (a space, a tab, a CR)
# and no newline after the last: it rejected the first and skipped the
# last row without a word.
import subprocess, tempfile
want = ['|'.join((l, i, n, ','.join(u), d, r)) for l, i, n, u, d, r in rows]
def rows_by_bash(path):
    p = subprocess.run(['Scripts/doc-types-rows.sh', path], capture_output=True, text=True)
    return p.returncode, p.stdout.splitlines(), p.stderr.strip()
code, got, err = rows_by_bash(src)
check(code == 0 and got == want, f"bundle-app.sh's reader reads the rows as Python does ({code} {err})")
with open(src) as f:
    lines = f.read().split('\n')
odd = []
for k, l in enumerate(lines):
    s = l.strip()
    odd.append(l if not s or s.startswith('#') else l + ['  ', '\t', ' \r'][k % 3])
with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as t:
    t.write('\n'.join(odd).rstrip('\n'))
    oddpath = t.name
try:
    code, got, err = rows_by_bash(oddpath)
    check(code == 0 and got == want, f"…and with whitespace after rows and no final newline ({code} {err}, {len(got)} of {len(want)} rows)")
finally:
    os.unlink(oddpath)
docs = pl.get('CFBundleDocumentTypes', [])
by_name = {d.get('CFBundleTypeName'): d for d in docs}
for label, icon, name, utis, decl, rank in rows:
    d = by_name.get(name)
    check(d is not None, f"{label}: a document type named {name!r}")
    if d is None:
        continue
    check(d.get('LSItemContentTypes') == utis, f"{label}: claims {utis}")
    check(d.get('CFBundleTypeIconFile') == icon + '.icns', f"{label}: icon {icon}.icns")
    check(os.path.isfile(os.path.join(res, icon + '.icns')), f"{label}: {icon}.icns is in the bundle")
    check(d.get('CFBundleTypeRole') == 'Editor', f"{label}: role Editor")
    check(rank in ('None', 'Alternate') and d.get('LSHandlerRank') == rank, f"{label}: LSHandlerRank {rank}")
text_names = {r[2] for r in rows}
others = [d for d in docs if d.get('CFBundleTypeName') not in text_names]
check(len(others) == 3 and all(d.get('LSHandlerRank') == 'Alternate' for d in others), "PDF, Image and Office types are Alternate")
check(not any(d.get('LSHandlerRank') in ('Owner', 'Default') or 'LSHandlerRank' not in d for d in docs), "no Owner/Default rank anywhere")
check(not any('CFBundleTypeIconSystemGenerated' in d for d in docs), "no CFBundleTypeIconSystemGenerated")
claims = [u for label, icon, name, utis, decl, rank in rows if label != '*' for u in utis]
check(len(claims) == len(set(claims)), "no content type is in two labelled types")
# Alternate claims are exactly 0.2.x's Text entry's, each once: claim
# parity with 0.5.3 (the same content types at the same ranks), which is
# all this checks; which app macOS picks is Launch Services' call. Only
# MD, JSON and YAML hold theirs in their labelled row (Finder shows that
# row's icon); a labelled row at Alternate for public.xml or public.css
# took them from Safari on a clean macOS 26 VM (1653a51).
labelled_alt = sorted(name for label, icon, name, utis, decl, rank in rows if label != '*' and rank == 'Alternate')
check(labelled_alt == ['JSON', 'Markdown', 'YAML'], f"Alternate labelled rows are exactly MD, JSON, YAML: {labelled_alt}")
alt = [u for d in docs if d.get('CFBundleTypeName') in text_names and d.get('LSHandlerRank') == 'Alternate'
       for u in d.get('LSItemContentTypes', [])]
check(sorted(alt) == sorted(['public.text', 'public.plain-text', 'public.source-code', 'public.script', 'public.json',
                             'public.yaml', 'public.html', 'public.xml', 'public.css', 'net.daringfireball.markdown',
                             'public.log', 'public.data']), f"Alternate text claims are 0.2.x's, once each: {alt}")
every = [u for d in docs if d.get('CFBundleTypeName') in text_names for u in d.get('LSItemContentTypes', [])]
# As in 0.5.3: these are in a labelled row at None and in "*" at Alternate.
dup = sorted({u for u in every if every.count(u) > 1})
check(dup == ['public.css', 'public.html', 'public.log', 'public.plain-text', 'public.xml'],
      f"only plain-text, xml, html, css and log are in two rows (labelled None + \"*\"): {dup}")
imp = {t['UTTypeIdentifier']: t for t in pl.get('UTImportedTypeDeclarations', [])}
want = {utis[0]: (name, decl) for label, icon, name, utis, decl, rank in rows if decl != '-'}
check(set(imp) == set(want), f"imported declarations are exactly {sorted(want)}")
for uti, (name, decl) in want.items():
    t = imp.get(uti, {})
    conf, exts = decl.split(';')
    check(t.get('UTTypeConformsTo') == conf.split(','), f"{uti} conforms to {conf}")
    check(t.get('UTTypeTagSpecification', {}).get('public.filename-extension') == exts.split(','), f"{uti} extensions {exts}")
    check('UTTypeIcons' not in t, f"{uti} has no UTTypeIcons")
check('UTExportedTypeDeclarations' not in pl, "no exported types (Owlink owns no format)")
print(f"doctypes: done {fails} failed")
sys.exit(1 if fails else 0)
PY

#!/usr/bin/env python3
"""Writes the small read-only viewer fixtures in ios/Samples:

  sample.pdf   a valid two-page PDF whose first page reads "Owlink PDF sample"
  sample.xlsx  a minimal valid workbook (one sheet, shared strings, styles)
               whose first cell reads "Owlink XLSX sample"
  multi-sheet.xlsx  three sheets (Owls, Sightings, Notes): shared and
               rich-text strings, numbers, a percent, dates, booleans, an
               error and gaps, for the grid viewer and its screenshots
  sample.csv   a small CSV (quoted fields, embedded commas and quotes)

Both are generated from scratch (no user files) and are deterministic: the
zip entries carry a fixed timestamp, so re-running gives the same bytes.
The UI tests open them with `-OwlinkOpen sample.pdf` / `sample.xlsx`.

    python3 ios/Scripts/make-doc-samples.py
"""
import os, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'Samples')


def make_pdf(path):
    pages = [
        [('Owlink PDF sample', 36, 72, 700), ('Page 1 of 2: read-only viewer fixture.', 14, 72, 660)],
        [('Owlink PDF sample, page 2', 24, 72, 700)],
    ]
    objs = []  # body of objects 1..n

    def add(body):
        objs.append(body)
        return len(objs)

    catalog = add(None)
    pages_obj = add(None)
    font = add(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    kids = []
    for lines in pages:
        stream = b''.join(b'BT /F1 %d Tf %d %d Td (%s) Tj ET\n' % (size, x, y, text.encode('ascii'))
                          for text, size, x, y in lines)
        content = add(b'<< /Length %d >>\nstream\n%sendstream' % (len(stream), stream))
        kids.append(add(b'<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] '
                        b'/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>' % (pages_obj, font, content)))
    objs[catalog - 1] = b'<< /Type /Catalog /Pages %d 0 R >>' % pages_obj
    objs[pages_obj - 1] = b'<< /Type /Pages /Kids [%s] /Count %d >>' % (
        b' '.join(b'%d 0 R' % k for k in kids), len(kids))

    out = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b'%d 0 obj\n%s\nendobj\n' % (i, body)
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for o in offsets:
        out += b'%010d 00000 n \n' % o
    out += b'trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, catalog, xref)
    with open(path, 'wb') as f:
        f.write(out)


XLSX = {
    '[Content_Types].xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>''',
    '_rels/.rels': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''',
    'xl/workbook.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Owls" sheetId="1" r:id="rId1"/></sheets>
</workbook>''',
    'xl/_rels/workbook.xml.rels': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''',
    'xl/sharedStrings.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="6" uniqueCount="6">
<si><t>Owlink XLSX sample</t></si><si><t>Owl</t></si><si><t>Count</t></si>
<si><t>Barn owl</t></si><si><t>Snowy owl</t></si><si><t>Tawny owl</t></si>
</sst>''',
    'xl/styles.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
</styleSheet>''',
    'xl/worksheets/sheet1.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<dimension ref="A1:B5"/>
<sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c></row>
<row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2" t="s"><v>2</v></c></row>
<row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>12</v></c></row>
<row r="4"><c r="A4" t="s"><v>4</v></c><c r="B4"><v>3.5</v></c></row>
<row r="5"><c r="A5" t="s"><v>5</v></c><c r="B5"><v>42</v></c></row>
</sheetData>
</worksheet>''',
}


def make_xlsx(path):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, text in XLSX.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 27, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, text.encode('utf-8'))


def esc(t):
    return t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def col(i):
    s = ''
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


def sheet_xml(rows, extra=''):
    """rows: lists of cells, each None (empty) or (type, value, style)."""
    out = []
    for r, cells in enumerate(rows, 1):
        cs = []
        for c, cell in enumerate(cells or []):
            if cell is None:
                continue
            t, v, st = cell
            ref = '%s%d' % (col(c), r)
            sa = ' s="%d"' % st if st else ''
            if t == 'n':
                cs.append('<c r="%s"%s><v>%s</v></c>' % (ref, sa, v))
            else:
                cs.append('<c r="%s" t="%s"%s><v>%s</v></c>' % (ref, t, sa, esc(str(v))))
        if cs:
            out.append('<row r="%d">%s</row>' % (r, ''.join(cs)))
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetData>%s%s</sheetData></worksheet>' % (''.join(out), extra))


NS_MAIN = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
NS_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
NS_PKG = 'http://schemas.openxmlformats.org/package/2006/relationships'
WS_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'


def make_multi_xlsx(path):
    strings = []

    def s(text):
        if text not in strings:
            strings.append(text)
        return ('s', strings.index(text), 0)

    owls = [
        [s('Owl'), s('Scientific name'), s('Wingspan (cm)'), s('Weight (g)'), s('Nocturnal'), s('Share of sightings')],
        [s('Barn owl'), s('Tyto alba'), ('n', 95, 0), ('n', 470, 0), ('b', 1, 0), ('n', 0.18, 2)],
        [s('Snowy owl'), s('Bubo scandiacus'), ('n', 150, 0), ('n', 2100, 0), ('b', 0, 0), ('n', 0.07, 2)],
        [s('Great horned owl'), s('Bubo virginianus'), ('n', 127, 0), ('n', 1400, 0), ('b', 1, 0), ('n', 0.31, 2)],
        [s('Tawny owl'), s('Strix aluco'), ('n', 99, 0), ('n', 520, 0), ('b', 1, 0), ('n', 0.22, 2)],
        [s('Elf owl'), s('Micrathene whitneyi'), ('n', 27, 0), ('n', 40, 0), ('b', 1, 0), ('n', 0.04, 2)],
        [s('Burrowing owl'), s('Athene cunicularia'), ('n', 53, 0), ('n', 150, 0), ('b', 0, 0), ('n', 0.11, 2)],
        [s('Long-eared owl'), s('Asio otus'), ('n', 95, 0), ('n', 290, 0), ('b', 1, 0), ('n', 0.07, 2)],
        None,
        [s('Total'), None, None, ('n', 4970, 0), None, ('n', 1, 2)],
    ]
    sightings = [[s('Date'), s('Owl'), s('Count'), s('Place'), s('Ratio')]]
    places = ['Marsh trail', 'North meadow', 'Old barn', 'Pine ridge']
    names = ['Barn owl', 'Snowy owl', 'Tawny owl', 'Great horned owl', 'Elf owl']
    for i in range(40):
        ratio = ('e', '#DIV/0!', 0) if i == 6 else ('n', round(1 + (i % 9) / 8, 3), 0)
        sightings.append([('n', 45366 + i * 3, 1), s(names[i % 5]), ('n', 1 + (i * 7) % 5, 0), s(places[i % 4]), ratio])
    notes = [[s('Notes')], [s('Read-only: Owlink never changes this file.')], None, None,
             [None, None, s('A gap above and to the left')]]
    rich = len(strings)
    sst = ''.join('<si><t xml:space="preserve">%s</t></si>' % esc(t) for t in strings)
    sst += '<si><r><rPr><b/></rPr><t>Rich</t></r><r><t xml:space="preserve"> text runs</t></r></si>'
    sheets = ['Owls', 'Sightings', 'Notes']
    files = {
        'xl/worksheets/sheet1.xml': sheet_xml(owls),
        'xl/worksheets/sheet2.xml': sheet_xml(sightings),
        'xl/worksheets/sheet3.xml': sheet_xml(notes, '<row r="7"><c r="A7" t="s"><v>%d</v></c></row>' % rich),
        '[Content_Types].xml': XLSX['[Content_Types].xml'].replace(
            '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="%s"/>' % WS_TYPE,
            ''.join('<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="%s"/>' % (i, WS_TYPE) for i in (1, 2, 3))),
        '_rels/.rels': XLSX['_rels/.rels'],
        'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<workbook xmlns="%s" xmlns:r="%s"><sheets>%s</sheets></workbook>' % (
                NS_MAIN, NS_REL, ''.join('<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (n, i, i)
                                         for i, n in enumerate(sheets, 1))),
        'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="%s">%s'
            '<Relationship Id="rId4" Type="%s/sharedStrings" Target="sharedStrings.xml"/>'
            '<Relationship Id="rId5" Type="%s/styles" Target="styles.xml"/></Relationships>' % (
                NS_PKG, ''.join('<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>' % (i, NS_REL, i)
                                for i in (1, 2, 3)), NS_REL, NS_REL),
        'xl/sharedStrings.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<sst xmlns="%s">%s</sst>' % (NS_MAIN, sst),
        'xl/styles.xml': XLSX['xl/styles.xml'].replace(
            '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>',
            '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
            '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
            '<xf numFmtId="9" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'),
    }
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 27, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, files[name].encode('utf-8'))


CSV_SAMPLE = '\n'.join([
    'Owl,Region,Wingspan (cm),Last seen,Note',
    'Barn owl,Worldwide,95,2024-03-15,"Hunts by sound, in total darkness"',
    'Snowy owl,Arctic,150,2024-01-02,Active by day',
    'Great horned owl,Americas,127,2023-12-24,"Also called the ""tiger owl"""',
    'Tawny owl,Europe,99,2024-02-11,',
    'Elf owl,Southwest US,27,2024-04-30,Smallest on the list',
]) + '\n'


if __name__ == '__main__':
    make_pdf(os.path.join(OUT, 'sample.pdf'))
    make_xlsx(os.path.join(OUT, 'sample.xlsx'))
    make_multi_xlsx(os.path.join(OUT, 'multi-sheet.xlsx'))
    with open(os.path.join(OUT, 'sample.csv'), 'w', newline='\n') as f:
        f.write(CSV_SAMPLE)
    for n in ('sample.pdf', 'sample.xlsx', 'multi-sheet.xlsx', 'sample.csv'):
        print(n, os.path.getsize(os.path.join(OUT, n)), 'bytes')

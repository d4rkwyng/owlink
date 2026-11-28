#!/usr/bin/env python3
"""Writes the small read-only viewer fixtures in ios/Samples:

  sample.pdf   a valid two-page PDF whose first page reads "Owlink PDF sample"
  sample.xlsx  a minimal valid workbook (one sheet, shared strings, styles)
               whose first cell reads "Owlink XLSX sample"

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


if __name__ == '__main__':
    make_pdf(os.path.join(OUT, 'sample.pdf'))
    make_xlsx(os.path.join(OUT, 'sample.xlsx'))
    for n in ('sample.pdf', 'sample.xlsx'):
        print(n, os.path.getsize(os.path.join(OUT, n)), 'bytes')

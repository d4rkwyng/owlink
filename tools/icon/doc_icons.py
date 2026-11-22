#!/usr/bin/env python3
"""Owlink's document icons: one template (a white page with a folded corner,
Cedric the owl, a coral label with the type's name), one .icns
per file type.

    python3 tools/icon/doc_icons.py            # writes Resources/DocIcons/*.icns
    python3 tools/icon/doc_icons.py --out DIR  # write .icns somewhere else
    python3 tools/icon/doc_icons.py --preview DIR  # PNGs only, no .icns
    python3 tools/icon/doc_icons.py --sheet S  # also a contact sheet PNG at S

Needs Pillow and iconutil, like cedric_icon.py (colours and Canvas).

Why .icns files: Finder shows the icon named by CFBundleTypeIconFile in the
default app's CFBundleDocumentTypes entry. The other mechanism, UTTypeIcons
(badge + text composed by the system), only works on a type the app itself
exports and needs an asset catalog (actool, Xcode only); every type here is
declared by the system or by others. See docs/MANUAL.md, "File types,
default editor and document icons".

The list of types (label -> file name) must match DocumentTypes.all in
Sources/CedricCore/DocumentTypes.swift; Tests/CedricCoreTests checks that
each type's icon file exists.

Sizes: 16 to 512 px (no 1024: a document icon is never shown at 512 pt on
a Retina screen in Finder, and the 1024 doubles the file). The 16 and 32 px
icons are drawn directly on the pixel grid, not downsampled.
"""
import argparse, os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
import cedric_icon as ci  # noqa: E402

ROOT = ci.ROOT
OUT = os.path.join(ROOT, 'Resources', 'DocIcons')

# (label, icon file name without .icns). "" = the generic text icon (no label).
TYPES = [
    ('TXT', 'doc-txt'), ('MD', 'doc-md'), ('JSON', 'doc-json'), ('YAML', 'doc-yaml'), ('SWIFT', 'doc-swift'),
    ('PY', 'doc-py'), ('JS', 'doc-js'), ('TS', 'doc-ts'), ('SH', 'doc-sh'), ('LOG', 'doc-log'), ('CSV', 'doc-csv'),
    ('XML', 'doc-xml'), ('HTML', 'doc-html'), ('CSS', 'doc-css'), ('TOML', 'doc-toml'), ('INI', 'doc-ini'),
    ('SQL', 'doc-sql'), ('PS1', 'doc-ps1'), ('', 'doc-text'),
]

ICONSET = [  # (iconset file, pixel size); 512@2x left out on purpose (see top)
    ('icon_16x16.png', 16), ('icon_16x16@2x.png', 32), ('icon_32x32.png', 32), ('icon_32x32@2x.png', 64),
    ('icon_128x128.png', 128), ('icon_128x128@2x.png', 256), ('icon_256x256.png', 256),
    ('icon_256x256@2x.png', 512), ('icon_512x512.png', 512),
]

PAGE = ci.hx('fdfdfd')
EDGE = ci.hx('c9cad6')
FOLD = ci.hx('e4e5ee')
LINE = ci.hx('d9dae6')

# Small badges use up to three compact glyphs.
SHORT_LABELS = {'JSON': 'JSN', 'YAML': 'YML', 'SWIFT': 'SW',
                'HTML': 'HTM', 'TOML': 'TML'}

# Each glyph is deliberately drawn on the output pixel grid at small sizes.
GLYPHS = {
    '1': ('010', '110', '010', '010', '111'),
    'A': ('010', '101', '111', '101', '101'),
    'C': ('011', '100', '100', '100', '011'),
    'D': ('110', '101', '101', '101', '110'),
    'F': ('111', '100', '110', '100', '100'),
    'G': ('011', '100', '101', '101', '011'),
    'H': ('101', '101', '111', '101', '101'),
    'I': ('111', '010', '010', '010', '111'),
    'J': ('011', '001', '001', '101', '010'),
    'L': ('100', '100', '100', '100', '111'),
    'M': ('10001', '11011', '10101', '10001', '10001'),
    'N': ('1001', '1101', '1011', '1001', '1001'),
    'O': ('010', '101', '101', '101', '010'),
    'P': ('110', '101', '110', '100', '100'),
    'Q': ('010', '101', '101', '111', '011'),
    'S': ('011', '100', '010', '001', '110'),
    'T': ('111', '010', '010', '010', '010'),
    'V': ('101', '101', '101', '101', '010'),
    'W': ('10001', '10001', '10101', '10101', '01010'),
    'X': ('101', '101', '010', '101', '101'),
    'Y': ('101', '101', '010', '010', '010'),
}

# Page geometry in the unit square (Apple's document shape is roughly 0.69 x 0.88).
X0, X1, Y0, Y1 = 0.155, 0.845, 0.06, 0.94
F = 0.19  # folded corner


def label_font(px):
    for f in ('/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/HelveticaNeue.ttc', '/System/Library/Fonts/Helvetica.ttc'):
        if os.path.exists(f):
            try:
                ft = ImageFont.truetype(f, px)
                try:
                    ft.set_variation_by_name('Bold')
                except Exception:
                    pass
                return ft
            except OSError:
                continue
    return ImageFont.load_default()


def page(c):
    n = c.n
    pts = [(X0, Y0), (X1 - F, Y0), (X1, Y0 + F), (X1, Y1), (X0, Y1)]
    # soft shadow, then the edge, then the page
    if c.size >= 64:
        from PIL import ImageFilter
        m = Image.new('L', (n, n), 0)
        ImageDraw.Draw(m).polygon([(x * n, (y + 0.012) * n) for x, y in pts], fill=255)
        c._fill(m.filter(ImageFilter.GaussianBlur(0.01 * n)), (0, 0, 0, 70))
    e = 0.012 if c.size >= 64 else 1.0 / c.size
    c.poly([(X0 - e, Y0 - e), (X1 - F + e * 0.4, Y0 - e), (X1 + e, Y0 + F - e * 0.4), (X1 + e, Y1 + e), (X0 - e, Y1 + e)], EDGE, owl=False)
    c.poly(pts, PAGE, owl=False)
    c.poly([(X1 - F, Y0), (X1 - F, Y0 + F), (X1, Y0 + F)], FOLD, owl=False)
    # a few faint text lines under the owl, from 128 px up
    if c.size >= 128:
        for i, (a, b) in enumerate(((0.25, 0.75), (0.25, 0.68), (0.25, 0.72))):
            y = 0.62 + i * 0.045
            c.rrect(a, y, b, y + 0.016, 0.008, LINE, owl=False)


def band(c, text):
    y0, y1 = 0.755, 0.885
    c.rrect(X0 + 0.045, y0, X1 - 0.045, y1, 0.035, ci.CORAL, owl=False)
    # the label, as large as fits the band
    d = ImageDraw.Draw(c.im)
    w_max = (X1 - X0 - 0.15) * c.n
    h_max = (y1 - y0) * c.n * 0.72
    px = int(h_max)
    while px > 4:
        ft = label_font(px)
        l, t, r, b = d.textbbox((0, 0), text, font=ft)
        if r - l <= w_max and b - t <= h_max:
            break
        px -= 1
    cx, cy = 0.5 * c.n, (y0 + y1) / 2 * c.n
    d.text((cx - (l + r) / 2, cy - (t + b) / 2), text, font=ft, fill=ci.WHITE)


def pixel_text(draw, text, y, sx, sy, width, ink=ci.WHITE):
    w = (sum(len(GLYPHS[ch][0]) for ch in text) + len(text) - 1) * sx
    x = (width - w) // 2
    for ch in text:
        for row, bits in enumerate(GLYPHS[ch]):
            for col, bit in enumerate(bits):
                if bit == '1':
                    left, top = x + col * sx, y + row * sy
                    draw.rectangle((left, top, left + sx - 1, top + sy - 1), fill=ink)
        x += (len(GLYPHS[ch][0]) + 1) * sx


def pixel_owl(draw):
    # Hand-built on the 32 px grid: pointed tufts, round rimmed eyes, and beak.
    draw.polygon([(9, 12), (9, 7), (14, 11), (16, 10), (18, 11),
                  (23, 7), (23, 12), (25, 16), (24, 20), (21, 22),
                  (11, 22), (8, 19), (7, 16)], fill=ci.NAVY)
    for x in (10, 18):
        draw.ellipse((x, 12, x + 5, 17), fill=ci.WHITE)
        draw.ellipse((x + 2, 14, x + 4, 16), fill=ci.NAVY)
    draw.polygon([(15, 17), (17, 17), (16, 19)], fill=ci.YEL)


def small_icon(text, size, include_owl=True):
    im = Image.new('RGBA', (size, size))
    d = ImageDraw.Draw(im)
    if size == 16:
        d.polygon([(1, 1), (10, 1), (14, 5), (14, 15), (1, 15)], fill=EDGE)
        d.polygon([(2, 2), (9, 2), (13, 6), (13, 14), (2, 14)], fill=PAGE)
        d.polygon([(9, 2), (9, 6), (13, 6)], fill=FOLD)
        if text:
            d.rectangle((1, 9, 14, 15), fill=ci.CORAL)
            pixel_text(d, SHORT_LABELS.get(text, text), 10, 1, 1, size, ci.NAVY)
    else:
        d.polygon([(4, 1), (19, 1), (27, 9), (27, 30), (4, 30)], fill=EDGE)
        d.polygon([(5, 2), (18, 2), (26, 10), (26, 29), (5, 29)], fill=PAGE)
        d.polygon([(18, 2), (18, 10), (26, 10)], fill=FOLD)
        if include_owl:
            pixel_owl(d)
        if text:
            d.rectangle((7, 24, 24, 28), fill=ci.CORAL)
            pixel_text(d, SHORT_LABELS.get(text, text), 24, 1, 1, size, ci.NAVY)
    return im


def small_band(im, text):
    size = im.width
    y0, y1 = round(0.72 * size), round(0.91 * size)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((round((X0 + 0.055) * size), y0,
                         round((X1 - 0.055) * size), y1), radius=2, fill=ci.CORAL)
    pixel_text(d, SHORT_LABELS.get(text, text), y0 + (y1 - y0 - 10) // 2,
               2, 2, size, ci.NAVY)


def doc_icon(text, size):
    if size == 16:
        return small_icon(text, size)
    if size == 32:
        return small_icon(text, size)
    c = ci.Canvas(size, s=0.52, ox=0.5, oy=0.60)
    page(c)
    ci.owl(c, chevron=size >= 64)
    if text:
        if size == 64:
            image = c.image()
            small_band(image, text)
            return image
        else:
            band(c, text)
    return c.image()


def build(out=OUT, sheet=None):
    os.makedirs(out, exist_ok=True)
    made = {}
    for text, name in TYPES:
        cache = {}
        with tempfile.TemporaryDirectory() as w:
            iset = os.path.join(w, name + '.iconset')
            os.makedirs(iset)
            for fn, px in ICONSET:
                if px not in cache:
                    cache[px] = doc_icon(text, px)
                cache[px].save(os.path.join(iset, fn))
            subprocess.run(['iconutil', '-c', 'icns', iset, '-o', os.path.join(out, name + '.icns')], check=True)
        made[name] = (text, cache)
    # Drop leftovers from an older type list, but only in the committed
    # Resources/DocIcons directory. --out must never delete from a scratch dir.
    if os.path.abspath(out) == os.path.abspath(OUT):
        keep = {name + '.icns' for _, name in TYPES}
        for f in os.listdir(out):
            if f.endswith('.icns') and f not in keep:
                os.remove(os.path.join(out, f))
    if sheet:
        write_sheet(sheet, made)
    return made


def preview(out):
    os.makedirs(out, exist_ok=True)
    sizes = (16, 32, 64, 128)
    backgrounds = {'light': (236, 236, 240, 255), 'dark': (42, 42, 46, 255)}
    images = {name: {s: doc_icon(text, s) for s in sizes} for text, name in TYPES}
    for theme, bg in backgrounds.items():
        sheet = Image.new('RGBA', (610, 42 + len(TYPES) * 148), bg)
        draw = ImageDraw.Draw(sheet)
        font = label_font(13)
        ink = ci.NAVY if theme == 'light' else ci.WHITE
        for x, label in ((10, 'Type'), (160, '16 px'), (240, '32 px'),
                         (330, '64 px'), (430, '128 px')):
            draw.text((x, 8), label, font=font, fill=ink)
        for row, (text, name) in enumerate(TYPES):
            y = 42 + row * 148
            draw.text((10, y + 5), name, font=font, fill=ink)
            for size in sizes:
                image = images[name][size]
                x = {16: 160, 32: 240, 64: 330, 128: 430}[size]
                sheet.alpha_composite(image, (x, y))
                composite = Image.new('RGBA', image.size, bg)
                composite.alpha_composite(image)
                composite.convert('RGB').save(os.path.join(out, f'{name}-{size}-{theme}.png'))
                if size in (16, 32):
                    composite.resize((size * 4, size * 4), Image.Resampling.NEAREST).convert('RGB').save(
                        os.path.join(out, f'{name}-{size}-{theme}-x4.png'))
        sheet.convert('RGB').save(os.path.join(out, f'contact-{theme}.png'))


def write_sheet(path, made):
    sizes = [256, 128, 64, 32, 16]
    pad = 16
    row_w = sum(sizes) + pad * (len(sizes) + 1)
    rows = len(made)
    sh = Image.new('RGBA', (row_w * 2, (256 + pad) * ((rows + 1) // 2) + pad), (236, 236, 240, 255))
    for i, (name, (text, cache)) in enumerate(made.items()):
        x = pad + (i % 2) * row_w
        y = pad + (i // 2) * (256 + pad)
        for s in sizes:
            sh.alpha_composite(cache[s], (x, y + 256 - s))
            x += s + pad
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    sh.save(path)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    dest = ap.add_mutually_exclusive_group()
    dest.add_argument('--out', help='directory for generated .icns files')
    dest.add_argument('--preview', help='write composited PNGs only')
    ap.add_argument('--sheet')
    a = ap.parse_args()
    if a.preview:
        if a.sheet:
            ap.error('--sheet requires .icns generation, not --preview')
        preview(a.preview)
        print(f'wrote previews for {len(TYPES)} icons to {a.preview}')
    else:
        out = a.out or OUT
        build(out, a.sheet)
        total = sum(os.path.getsize(os.path.join(out, name + '.icns')) for _, name in TYPES)
        print(f'wrote {len(TYPES)} icons to {out} ({total // 1024} KB)')

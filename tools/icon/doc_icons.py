#!/usr/bin/env python3
"""Owlink's type-coloured Finder document icons.

    python3 tools/icon/doc_icons.py                 # Resources/DocIcons/*.icns
    python3 tools/icon/doc_icons.py --out DIR       # .icns in another directory
    python3 tools/icon/doc_icons.py --preview DIR   # composited PNGs, no .icns
    python3 tools/icon/doc_icons.py --sheet PATH    # also write a contact sheet

Requires Pillow and iconutil. TYPES must match Resources/document-types.txt.
The iconset omits 512@2x: Finder does not show documents at 512 pt on Retina.
"""
import argparse, os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
import cedric_icon as ci  # noqa: E402

ROOT = ci.ROOT
OUT = os.path.join(ROOT, 'Resources', 'DocIcons')

TYPES = [
    ('TXT', 'doc-txt'), ('MD', 'doc-md'), ('JSON', 'doc-json'), ('YAML', 'doc-yaml'), ('SWIFT', 'doc-swift'),
    ('PY', 'doc-py'), ('JS', 'doc-js'), ('TS', 'doc-ts'), ('SH', 'doc-sh'), ('LOG', 'doc-log'), ('CSV', 'doc-csv'),
    ('XML', 'doc-xml'), ('HTML', 'doc-html'), ('CSS', 'doc-css'), ('TOML', 'doc-toml'), ('INI', 'doc-ini'),
    ('SQL', 'doc-sql'), ('PS1', 'doc-ps1'), ('', 'doc-text'),
]

ICONSET = [
    ('icon_16x16.png', 16), ('icon_16x16@2x.png', 32), ('icon_32x32.png', 32), ('icon_32x32@2x.png', 64),
    ('icon_128x128.png', 128), ('icon_128x128@2x.png', 256), ('icon_256x256.png', 256),
    ('icon_256x256@2x.png', 512), ('icon_512x512.png', 512),
]

# White ink on every page is at least 4.5:1. The glyph name is also used
# for the hand-tuned 16 px master and the larger, smoothly drawn versions.
STYLES = {
    'MD':    ('b83a26', 'hash',    'MD'),
    'HTML':  ('a83422', 'tag',     'HTML'),
    'CSS':   ('9c3820', 'star',    'CSS'),
    'TXT':   ('27295a', 'lines',   'TXT'),
    'LOG':   ('3b3e7c', 'log',     'LOG'),
    '':      ('1f2148', 'dash',    ''),
    'JSON':  ('8a5a00', 'braces',  'JSON'),
    'YAML':  ('7a4e00', 'list',    'YAML'),
    'TOML':  ('6e4600', 'brackets', 'TOML'),
    'CSV':   ('8a5a18', 'grid',    'CSV'),
    'XML':   ('5c3c00', 'xml',     'XML'),
    'INI':   ('805010', 'equals',  'INI'),
    'SWIFT': ('4a52b5', 'code',    'SWFT'),
    'PY':    ('4a4090', 'lambda',  'PY'),
    'JS':    ('3550b0', 'parens',  'JS'),
    'TS':    ('3d46a0', 'generic', 'TS'),
    'SH':    ('2e3478', 'dollar',  'SH'),
    'PS1':   ('4540a0', 'prompt',  'PS1'),
    'SQL':   ('2c3888', 'table',   'SQL'),
}

# Seven-column pixel masters: no letters at 16 pt, including on Retina.
PIXELS = {
    'hash':     ('0100100', '1111110', '0100100', '1111110', '0100100'),
    'tag':      ('0010100', '0100010', '1000001', '0100010', '0010100'),
    'star':     ('1001001', '0101010', '1111111', '0101010', '1001001'),
    'lines':    ('1111111', '0000000', '1111111', '0000000', '1111111'),
    'log':      ('1111100', '0000000', '1111000', '0000000', '1111100'),
    'dash':     ('0000000', '0000000', '0111110', '0000000', '0000000'),
    'braces':   ('0110110', '0100010', '1100011', '0100010', '0110110'),
    'list':     ('1101111', '0000000', '1101110', '0000000', '1101111'),
    'brackets': ('1100011', '1000001', '1000001', '1000001', '1100011'),
    'grid':     ('1111111', '1010101', '1111111', '1010101', '1111111'),
    'xml':      ('0010010', '0100010', '1000100', '0100100', '0011000'),
    'equals':   ('0000000', '1111110', '0000000', '1111110', '0000000'),
    'code':     ('0010100', '0100101', '1001010', '0101001', '0010100'),
    'lambda':   ('1100000', '0010000', '0010000', '0101000', '1000100'),
    'parens':   ('0100010', '1000001', '1000001', '1000001', '0100010'),
    'generic':  ('0010100', '0100010', '1001001', '0100010', '0010100'),
    'dollar':   ('0011100', '0110000', '0011100', '0000110', '0111000', '0001000'),
    'prompt':   ('1000000', '0100000', '0010000', '0100000', '1001111'),
    'table':    ('1111111', '1001001', '1111111', '1001001', '1111111', '1001001'),
}

# Paths in a 0..1 glyph square. These correspond to the pixel masters but
# retain clean, bold strokes when the icon is viewed at larger sizes.
PATHS = {
    'hash': [((.3, 0), (.3, 1)), ((.7, 0), (.7, 1)), ((0, .3), (1, .3)), ((0, .7), (1, .7))],
    'tag': [((.4, 0), (0, .5), (.4, 1)), ((.6, 0), (1, .5), (.6, 1))],
    'star': [((.5, 0), (.5, 1)), ((0, .5), (1, .5)), ((.15, .15), (.85, .85)), ((.85, .15), (.15, .85))],
    'lines': [((0, .1), (1, .1)), ((0, .5), (1, .5)), ((0, .9), (1, .9))],
    'log': [((0, .1), (.8, .1)), ((0, .5), (.6, .5)), ((0, .9), (.8, .9))],
    'dash': [((.15, .5), (.85, .5))],
    'braces': [((.35, 0), (.2, 0), (.2, .4), (0, .5), (.2, .6), (.2, 1), (.35, 1)),
               ((.65, 0), (.8, 0), (.8, .4), (1, .5), (.8, .6), (.8, 1), (.65, 1))],
    'list': [((0, .1), (.12, .1)), ((.35, .1), (1, .1)), ((0, .5), (.12, .5)), ((.35, .5), (.85, .5)), ((0, .9), (.12, .9)), ((.35, .9), (1, .9))],
    'brackets': [((.32, 0), (.15, 0), (.15, 1), (.32, 1)), ((.68, 0), (.85, 0), (.85, 1), (.68, 1))],
    'grid': [((0, 0), (1, 0), (1, 1), (0, 1), (0, 0)), ((.5, 0), (.5, 1)), ((0, .5), (1, .5))],
    'xml': [((.45, 0), (0, .5), (.45, 1)), ((1, 0), (.65, 1))],
    'equals': [((0, .3), (1, .3)), ((0, .7), (1, .7))],
    'code': [((.35, 0), (0, .5), (.35, 1)), ((.65, 0), (1, .5), (.65, 1)), ((.62, 0), (.38, 1))],
    'lambda': [((.1, 0), (.35, 0), (.8, 1)), ((.5, .45), (.1, 1))],
    'parens': [((.3, 0), (.15, .25), (.15, .75), (.3, 1)), ((.7, 0), (.85, .25), (.85, .75), (.7, 1))],
    'generic': [((.3, 0), (0, .5), (.3, 1)), ((.7, 0), (1, .5), (.7, 1)), ((.5, .4), (.5, .6))],
    'dollar': [((.85, .15), (.25, .15), (.1, .35), (.75, .65), (.85, .85), (.15, .85)), ((.5, 0), (.5, 1))],
    'prompt': [((0, .1), (.4, .45), (0, .8)), ((.55, .9), (1, .9))],
    'table': [((0, 0), (1, 0), (1, 1), (0, 1), (0, 0)), ((0, .3), (1, .3)), ((0, .65), (1, .65)), ((.5, .3), (.5, 1))],
}

X0, X1, Y0, Y1 = 0.155, 0.845, 0.06, 0.94
F = 0.19
RIM = ci.hx('e8e8ee')
RIM_TYPES = {'', 'TXT', 'LOG', 'SH', 'SQL'}


def shade(color, target, amount):
    return tuple(round(c * (1 - amount) + target * amount) for c in color[:3]) + (255,)


def label_font(px):
    for path in ('/System/Library/Fonts/Supplemental/Arial Bold.ttf',
                 '/System/Library/Fonts/HelveticaNeue.ttc'):
        if os.path.exists(path):
            return ImageFont.truetype(path, px)
    raise RuntimeError('A bold system font is required to draw document labels')


def page(c, text):
    color = ci.hx(STYLES[text][0])
    edge = shade(color, 0, .25)
    fold = shade(color, 255, .16)
    n = c.n
    pts = [(X0, Y0), (X1 - F, Y0), (X1, Y0 + F), (X1, Y1), (X0, Y1)]
    if c.size >= 64:
        from PIL import ImageFilter
        mask = Image.new('L', (n, n), 0)
        ImageDraw.Draw(mask).polygon([(x * n, (y + .012) * n) for x, y in pts], fill=255)
        c._fill(mask.filter(ImageFilter.GaussianBlur(.01 * n)), (0, 0, 0, 70))
    e = .012 if c.size >= 64 else 1.0 / c.size
    outline = [(X0 - e, Y0 - e), (X1 - F + e * .4, Y0 - e),
               (X1 + e, Y0 + F - e * .4), (X1 + e, Y1 + e), (X0 - e, Y1 + e)]
    if text in RIM_TYPES:
        r = .006
        c.poly([(X0 - e - r, Y0 - e - r), (X1 - F + e * .4, Y0 - e - r),
                (X1 + e + r, Y0 + F - e * .4), (X1 + e + r, Y1 + e + r),
                (X0 - e - r, Y1 + e + r)], RIM, owl=False)
    c.poly(outline, edge, owl=False)
    c.poly(pts, color, owl=False)
    c.poly([(X1 - F, Y0), (X1 - F, Y0 + F), (X1, Y0 + F)], fold, owl=False)


def small_icon(text):
    color = ci.hx(STYLES[text][0])
    edge, fold = shade(color, 0, .25), shade(color, 255, .16)
    im = Image.new('RGBA', (16, 16))
    d = ImageDraw.Draw(im)
    if text in RIM_TYPES:
        d.polygon([(1, 0), (10, 0), (15, 5), (15, 15), (1, 15)], fill=RIM)
    d.polygon([(2, 1), (10, 1), (14, 5), (14, 15), (2, 15)], fill=edge)
    d.polygon([(3, 2), (9, 2), (13, 6), (13, 14), (3, 14)], fill=color)
    d.polygon([(9, 2), (9, 6), (13, 6)], fill=fold)
    rows = PIXELS[STYLES[text][1]]
    y0 = 7 if len(rows) == 5 else 6
    for y, row in enumerate(rows):
        for x, bit in enumerate(row):
            if bit == '1':
                d.point((5 + x, y0 + y), fill=ci.WHITE)
    return im


def draw_glyph(image, glyph, size, labelled):
    d = ImageDraw.Draw(image)
    # Keep ink clear of the lighter fold and above the lower-third label.
    x0, x1 = .30 * size, .70 * size
    y0, y1 = (.28, .62) if labelled else (.30, .68)
    stroke = max(2 if size == 32 else 1, round(.045 * size))
    for path in PATHS[glyph]:
        pts = [(round(x0 + x * (x1 - x0)), round((y0 + y * (y1 - y0)) * size)) for x, y in path]
        d.line(pts, fill=ci.WHITE, width=stroke, joint='curve')


def draw_label(c, text):
    d = ImageDraw.Draw(c.im)
    w_max, h_max = .55 * c.n, .15 * c.n
    px = int(.22 * c.n)
    while px > 1:
        font = label_font(px)
        l, t, r, b = d.textbbox((0, 0), text, font=font)
        if r - l <= w_max and b - t <= h_max:
            break
        px -= 1
    d.text((.5 * c.n - (l + r) / 2, .785 * c.n - (t + b) / 2),
           text, font=font, fill=ci.WHITE)


def doc_icon(text, size, scale=1):
    """Render a logical point size; the small masters stay on their pixel grid."""
    if size == 16:
        im = small_icon(text)
        return im.resize((16 * scale, 16 * scale), Image.Resampling.NEAREST)
    if size == 32:
        color = ci.hx(STYLES[text][0])
        im = Image.new('RGBA', (32, 32))
        d = ImageDraw.Draw(im)
        if text in RIM_TYPES:
            d.polygon([(3, 0), (19, 0), (28, 9), (28, 31), (3, 31)], fill=RIM)
        d.polygon([(4, 1), (19, 1), (27, 9), (27, 30), (4, 30)], fill=shade(color, 0, .25))
        d.polygon([(5, 2), (18, 2), (26, 10), (26, 29), (5, 29)], fill=color)
        d.polygon([(18, 2), (18, 10), (26, 10)], fill=shade(color, 255, .16))
        draw_glyph(im, STYLES[text][1], 32, False)
        return im.resize((32 * scale, 32 * scale), Image.Resampling.NEAREST)
    c = ci.Canvas(size * scale)
    page(c, text)
    _, glyph, label = STYLES[text]
    draw_glyph(c.im, glyph, c.n, bool(label))
    if label:
        draw_label(c, label)
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
                pt = int(fn.split('x')[0].split('_')[1])
                key = (pt, px // pt)
                if key not in cache:
                    cache[key] = doc_icon(text, *key)
                cache[key].save(os.path.join(iset, fn))
            subprocess.run(['iconutil', '-c', 'icns', iset, '-o', os.path.join(out, name + '.icns')], check=True)
        made[name] = (text, {s: doc_icon(text, s) for s in (16, 32, 64, 128, 256)})
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

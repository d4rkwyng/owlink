import colorsys
import io
import os
import tempfile
import unittest
from unittest.mock import Mock, patch

from PIL import Image, ImageDraw
import doc_icons as icons


def luminance(color):
    channels = [v / 255 for v in color[:3]]
    linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in channels]
    return .2126 * linear[0] + .7152 * linear[1] + .0722 * linear[2]


class DocumentIconTests(unittest.TestCase):
    def test_types_match_document_manifest(self):
        path = os.path.join(icons.ROOT, 'Resources', 'document-types.txt')
        with open(path) as f:
            rows = [line.strip().split('|') for line in f if line.strip() and not line.startswith('#')]
        self.assertEqual({(label if label != '*' else '', name) for label, name, *_ in rows},
                         set(icons.TYPES))
        self.assertEqual(len(icons.TYPES), len(set(name for _, name in icons.TYPES)))
        self.assertEqual(set(icons.STYLES), {text for text, _ in icons.TYPES})

    def test_white_ink_has_aa_contrast_on_every_page(self):
        for text, _ in icons.TYPES:
            with self.subTest(text=text):
                page = icons.ci.hx(icons.STYLES[text][0])
                self.assertGreaterEqual((1.05 / (luminance(page) + .05)), 4.5)

    def test_16pt_pages_and_glyphs_are_distinct(self):
        images = [icons.doc_icon(text, 16).tobytes() for text, _ in icons.TYPES]
        self.assertEqual(len(images), len(set(images)))
        masters = [icons.PIXELS[icons.STYLES[text][1]] for text, _ in icons.TYPES]
        self.assertEqual(len(masters), len(set(masters)))

    def test_small_icons_have_white_glyphs_and_no_labels_or_owl(self):
        for text, _ in icons.TYPES:
            for size in (16, 32):
                with self.subTest(text=text, size=size):
                    with patch.object(icons, 'draw_label') as label, patch.object(icons.ci, 'owl') as owl:
                        image = icons.doc_icon(text, size)
                    label.assert_not_called()
                    owl.assert_not_called()
                    self.assertIn(icons.ci.WHITE, {color for _, color in image.getcolors(size * size)})
                    self.assertEqual(image.getpixel((0, 0))[3], 0)

    def fold_mask(self, size, factor=1):
        """How much of each pixel the fold covers at size * factor px
        (255: wholly inside; 16/32 and the supersampled canvas are 0 or 255)."""
        if size in (16, 32):
            mask = Image.new('L', (size, size))
            ImageDraw.Draw(mask).polygon(icons.SMALL_FOLD[size], fill=255)
            return mask
        n = size * icons.ci.SS
        mask = Image.new('L', (n, n))
        ImageDraw.Draw(mask).polygon([((icons.X1 - icons.F) * n, icons.Y0 * n),
                                      ((icons.X1 - icons.F) * n, (icons.Y0 + icons.F) * n),
                                      (icons.X1 * n, (icons.Y0 + icons.F) * n)], fill=255)
        return mask if factor == icons.ci.SS else mask.resize((size, size), Image.Resampling.BOX)

    def assert_fold_has_no_light_ink(self, image, mask, text, size, tolerance):
        # Compare the lightest channel with the fold colour, so a Lanczos
        # blend of white ink fails as well as pure white.
        fold = min(icons.shade(icons.ci.hx(icons.STYLES[text][0]), 255, .16)[:3])
        pixels, coverage = image.load(), mask.load()
        for y in range(mask.height):
            for x in range(mask.width):
                if coverage[x, y] == 255:
                    self.assertLessEqual(min(pixels[x, y][:3]) - fold, tolerance,
                                         ('inside', text, size, x, y, pixels[x, y]))
                elif coverage[x, y]:
                    # Partly covered: the fold's edge, mixed with the page,
                    # the outline ring or the transparent margin, all no
                    # lighter than the fold, so the same bound holds. White
                    # ink blended into an edge pixel still fails it (TOML's
                    # nick at 2b2bacb showed only here, 20-90 levels over).
                    self.assertLessEqual(min(pixels[x, y][:3]) - fold, tolerance,
                                         ('edge', coverage[x, y], text, size, x, y, pixels[x, y]))

    def test_white_ink_stays_clear_of_fold(self):
        # Shipped pixels: 16/32 are drawn on the pixel grid; 64 and up are
        # Lanczos downsamples, checked on every pixel the fold touches.
        # Seams where the fold meets the outline ring are at most a few
        # levels over the fold; a blended glyph stroke is far above 16.
        for size in (16, 32, 64, 128, 256):
            mask = self.fold_mask(size)
            for text, _ in icons.TYPES:
                with self.subTest(text=text, size=size):
                    self.assert_fold_has_no_light_ink(icons.doc_icon(text, size), mask, text, size, 16)

    def test_fold_check_sees_ink_on_partly_covered_pixels(self):
        # A near-white blend in one edge pixel only (none inside) must fail.
        size, text = 128, 'TOML'
        mask = self.fold_mask(size)
        image = icons.doc_icon(text, size)
        self.assert_fold_has_no_light_ink(image, mask, text, size, 16)
        edge = [(x, y) for y in range(size) for x in range(size) if 0 < mask.getpixel((x, y)) < 255]
        self.assertTrue(edge)
        x, y = edge[len(edge) // 2]
        fold = min(icons.shade(icons.ci.hx(icons.STYLES[text][0]), 255, .16)[:3])
        image.putpixel((x, y), (fold + 40,) * 3 + (255,))
        with self.assertRaises(AssertionError):
            self.assert_fold_has_no_light_ink(image, mask, text, size, 16)

    def test_supersampled_glyph_stays_clear_of_fold(self):
        # Before the downsample the fold is one flat colour, so no glyph ink at all.
        for size in (64, 128, 256):
            mask = self.fold_mask(size, icons.ci.SS)
            for text, _ in icons.TYPES:
                with self.subTest(text=text, size=size):
                    c = icons.ci.Canvas(size)
                    icons.page(c, text)
                    _, glyph, label = icons.STYLES[text]
                    icons.draw_glyph(c.im, glyph, c.n, bool(label))
                    self.assert_fold_has_no_light_ink(c.im, mask, text, size, 0)

    def test_small_glyph_ink_stays_inside_page(self):
        for size, page in (
            (16, [(3, 2), (9, 2), (13, 6), (13, 13), (3, 13)]),
            (32, [(5, 2), (18, 2), (26, 10), (26, 29), (5, 29)]),
        ):
            self.assertEqual(page, icons.SMALL_PAGE[size])
            mask = Image.new('L', (size, size))
            ImageDraw.Draw(mask).polygon(page, fill=255)
            for text, _ in icons.TYPES:
                with self.subTest(text=text, size=size):
                    image = icons.doc_icon(text, size)
                    for y in range(size):
                        for x in range(size):
                            if image.getpixel((x, y)) == icons.ci.WHITE:
                                self.assertNotEqual(mask.getpixel((x, y)), 0, (text, size, x, y))

    def test_label_font_selects_bold_variation(self):
        self.assertIn(icons.label_font(20).getname()[1], ('Bold', 'Heavy'))
        font = Mock()
        font.get_variation_names.return_value = [b'Regular', b'Heavy']
        with patch.object(icons.ImageFont, 'truetype', return_value=font):
            self.assertIs(icons.label_font(20), font)
            font.set_variation_by_name.assert_called_once_with('Heavy')
            font.get_variation_names.return_value = [b'Regular']
            with self.assertRaisesRegex(RuntimeError, 'bold SFNS'):
                icons.label_font(20)
        with patch.object(icons.ImageFont, 'truetype', side_effect=OSError('font unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'bold SFNS'):
                icons.label_font(20)

    def test_retina_small_icons_double_their_point_master(self):
        for text, _ in icons.TYPES:
            for size in (16, 32):
                with self.subTest(text=text, size=size):
                    expected = icons.doc_icon(text, size).resize((size * 2, size * 2), Image.Resampling.NEAREST)
                    self.assertEqual(icons.doc_icon(text, size, 2).tobytes(), expected.tobytes())

    def test_labels_start_at_64pt_and_generic_never_has_one(self):
        for text, _ in icons.TYPES:
            for size in (64, 128, 256):
                with self.subTest(text=text, size=size):
                    with patch.object(icons, 'draw_label', wraps=icons.draw_label) as label:
                        icons.doc_icon(text, size)
                    if text:
                        self.assertEqual(label.call_args.args[1], icons.STYLES[text][2])
                    else:
                        label.assert_not_called()
        self.assertEqual(icons.STYLES['SWIFT'][2], 'SWFT')

    def test_large_icons_render_lower_labels_without_a_mascot(self):
        for text, _ in icons.TYPES:
            for size in (64, 128, 256):
                with self.subTest(text=text, size=size):
                    with patch.object(icons.ci, 'owl') as owl:
                        image = icons.doc_icon(text, size)
                    owl.assert_not_called()
                    bottom = image.crop((0, round(46 * size / 64), size, round(57 * size / 64)))
                    white = sum(count for count, color in bottom.getcolors(size * size) if color == icons.ci.WHITE)
                    if text:
                        self.assertGreater(white, 0)
                    else:
                        self.assertEqual(white, 0)

    def test_dark_pages_have_pale_rim(self):
        for text in icons.RIM_TYPES:
            for size in (16, 32):
                with self.subTest(text=text, size=size):
                    image = icons.doc_icon(text, size)
                    self.assertIn(icons.RIM, {color for _, color in image.getcolors(size * size)})

    def test_finder_sizes_keep_every_canvas_edge_transparent(self):
        # Finder list view (16 pt) clipped the page and fold when they touched
        # the canvas edge. Check every edge pixel, including Retina images.
        for text, name in icons.TYPES:
            for size, scale in ((16, 1), (16, 2), (32, 1), (32, 2), (64, 1)):
                with self.subTest(name=name, size=size, scale=scale):
                    alpha = icons.doc_icon(text, size, scale).getchannel('A')
                    n = alpha.width
                    self.assertEqual(alpha.size, (size * scale, size * scale))
                    edge = {(x, y) for i in range(n) for x, y in ((i, 0), (i, n - 1), (0, i), (n - 1, i))}
                    touching = sorted(p for p in edge if alpha.getpixel(p))
                    self.assertEqual(touching, [], (name, size, scale))
                    # The page still fills most of the canvas.
                    l, t, r, b = alpha.getbbox()
                    self.assertGreaterEqual(min(r - l, b - t), .7 * n, (name, size, scale))

    def test_iconset_uses_logical_size_for_retina_images(self):
        # Inspect the actual PNGs passed to iconutil, including both 32 px entries.
        original = icons.TYPES
        captured = {}

        def fake_iconutil(args, check):
            for filename, _ in icons.ICONSET:
                with Image.open(os.path.join(args[3], filename)) as image:
                    captured[filename] = image.convert('RGBA').copy()
            with open(args[5], 'wb') as f:
                f.write(b'icns\x00\x00\x00\x08')

        with tempfile.TemporaryDirectory() as out:
            with patch.object(icons, 'TYPES', [('MD', 'doc-md')]), \
                 patch.object(icons.subprocess, 'run', side_effect=fake_iconutil):
                icons.build(out)
        self.assertEqual(icons.TYPES, original)
        for filename, px in icons.ICONSET:
            pt = int(filename.split('x')[0].split('_')[1])
            self.assertEqual(captured[filename].tobytes(), icons.doc_icon('MD', pt, px // pt).tobytes())
        self.assertNotEqual(captured['icon_16x16@2x.png'].tobytes(),
                            captured['icon_32x32.png'].tobytes())

    def test_txt_is_its_own_colour_not_the_generic_navy(self):
        def hue(text):
            r, g, b = (v / 255 for v in icons.ci.hx(icons.STYLES[text][0])[:3])
            return colorsys.rgb_to_hls(r, g, b)[0] * 360

        self.assertEqual(icons.STYLES['TXT'][2], 'TXT')
        self.assertNotIn('TXT', icons.RIM_TYPES)
        for text, _ in icons.TYPES:
            if text != 'TXT':
                with self.subTest(text=text):
                    d = abs(hue('TXT') - hue(text))
                    self.assertGreaterEqual(min(d, 360 - d), 40)

    def test_build_adds_labelled_64pt_element(self):
        with tempfile.TemporaryDirectory() as out:
            with patch.object(icons, 'TYPES', [('TXT', 'doc-txt')]):
                icons.build(out)
            path = os.path.join(out, 'doc-txt.icns')
            with open(path, 'rb') as f:
                elements = dict(icons.icns_elements(f.read()))
            # The patched file must still be a valid .icns for macOS.
            icons.subprocess.run(['iconutil', '-c', 'iconset', path, '-o', os.path.join(out, 'x.iconset')],
                                 check=True)
        self.assertIn(b'ic07', elements)
        with Image.open(io.BytesIO(elements[b'icp6'])) as image:
            self.assertEqual(image.convert('RGBA').tobytes(), icons.doc_icon('TXT', 64).tobytes())

    def test_add_elements_replaces_existing_element(self):
        with tempfile.TemporaryDirectory() as out:
            path = os.path.join(out, 'x.icns')
            with open(path, 'wb') as f:
                f.write(b'icns\x00\x00\x00\x08')
            icons.add_elements(path, [(b'icp6', icons.doc_icon('MD', 64))])
            icons.add_elements(path, [(b'icp6', icons.doc_icon('TXT', 64))])
            with open(path, 'rb') as f:
                elements = icons.icns_elements(f.read())
        self.assertEqual([k for k, _ in elements], [b'icp6'])
        with Image.open(io.BytesIO(elements[0][1])) as image:
            self.assertEqual(image.convert('RGBA').tobytes(), icons.doc_icon('TXT', 64).tobytes())

    def test_shipped_icons_include_labelled_64pt_element(self):
        for text, name in icons.TYPES:
            with self.subTest(name=name):
                with open(os.path.join(icons.OUT, name + '.icns'), 'rb') as f:
                    elements = dict(icons.icns_elements(f.read()))
                with Image.open(io.BytesIO(elements[b'icp6'])) as image:
                    self.assertEqual(image.convert('RGBA').tobytes(), icons.doc_icon(text, 64).tobytes())

    def test_preview_outputs_both_finder_backgrounds(self):
        with tempfile.TemporaryDirectory() as out:
            with patch.object(icons, 'TYPES', [('MD', 'doc-md')]):
                icons.preview(out)
            for theme in ('light', 'dark'):
                for name in (f'contact-{theme}.png', f'doc-md-16-{theme}-x4.png',
                             f'doc-md-128-{theme}.png'):
                    self.assertTrue(os.path.isfile(os.path.join(out, name)))


if __name__ == '__main__':
    unittest.main()

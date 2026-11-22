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

    def test_white_ink_stays_clear_of_fold(self):
        for size in (16, 32, 64, 128):
            if size == 16:
                fold = [(9, 2), (9, 6), (13, 6)]
                factor = 1
            elif size == 32:
                fold = [(18, 2), (18, 10), (26, 10)]
                factor = 1
            else:
                factor = icons.ci.SS
                n = size * factor
                fold = [((icons.X1 - icons.F) * n, icons.Y0 * n),
                        ((icons.X1 - icons.F) * n, (icons.Y0 + icons.F) * n),
                        (icons.X1 * n, (icons.Y0 + icons.F) * n)]
            mask = Image.new('L', (size * factor, size * factor))
            ImageDraw.Draw(mask).polygon(fold, fill=255)
            if factor > 1:
                mask = mask.resize((size, size), Image.Resampling.BOX)
            for text, _ in icons.TYPES:
                with self.subTest(text=text, size=size):
                    image = icons.doc_icon(text, size)
                    for y in range(size):
                        for x in range(size):
                            if mask.getpixel((x, y)):
                                self.assertNotEqual(image.getpixel((x, y)), icons.ci.WHITE,
                                                    (text, size, x, y))

    def test_small_glyph_ink_stays_inside_page(self):
        for size, page in (
            (16, [(3, 2), (9, 2), (13, 6), (13, 14), (3, 14)]),
            (32, [(5, 2), (18, 2), (26, 10), (26, 29), (5, 29)]),
        ):
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
                    if size == 16:
                        self.assertEqual(image.getpixel((15, 15))[3], 0)

    def test_iconset_uses_logical_size_for_retina_images(self):
        # Inspect the actual PNGs passed to iconutil, including both 32 px entries.
        original = icons.TYPES
        captured = {}

        def fake_iconutil(args, check):
            for filename, _ in icons.ICONSET:
                with Image.open(os.path.join(args[3], filename)) as image:
                    captured[filename] = image.convert('RGBA').copy()

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

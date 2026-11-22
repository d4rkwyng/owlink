import os
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
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
            with self.subTest(text=text):
                with patch.object(icons.ci, 'owl') as owl:
                    image = icons.doc_icon(text, 64)
                owl.assert_not_called()
                bottom = image.crop((0, 46, 64, 57))
                white = sum(1 for pixel in bottom.getdata() if pixel == icons.ci.WHITE)
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

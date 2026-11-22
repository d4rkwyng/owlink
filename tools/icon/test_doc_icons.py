import unittest
from unittest.mock import patch

import doc_icons as icons


class DocumentIconTests(unittest.TestCase):
    def test_small_labels_fit_and_are_distinct(self):
        labels = [icons.SHORT_LABELS.get(text, text) for text, _ in icons.TYPES if text]
        self.assertEqual(len(labels), len(set(labels)))
        self.assertTrue(all(len(label) <= 3 for label in labels))
        self.assertTrue(set(''.join(text for text, _ in icons.TYPES)) <= icons.GLYPHS.keys())
        self.assertTrue(all(sum(len(icons.GLYPHS[ch][0]) for ch in label) + len(label) - 1 <= 13
                            for label in labels))
        badges = [icons.doc_icon(text, 16).crop((1, 9, 15, 16)).tobytes()
                  for text, _ in icons.TYPES if text]
        self.assertEqual(len(badges), len(set(badges)))

    def test_small_labels_are_drawn_as_white_pixels_on_coral(self):
        for text, _ in icons.TYPES:
            if not text:
                continue
            for size, y in ((16, 10), (32, 20)):
                with self.subTest(text=text, size=size):
                    image = icons.doc_icon(text, size)
                    badge = image.crop((1, 9, 15, 16) if size == 16 else (2, 19, 30, 31))
                    colors = {color for _, color in badge.getcolors()}
                    self.assertEqual(colors, {icons.ci.WHITE, icons.ci.CORAL})

    def test_32px_badges_use_distinct_bold_short_labels(self):
        badges = []
        for text, _ in icons.TYPES:
            if not text:
                continue
            with self.subTest(text=text):
                with patch.object(icons, 'pixel_text', wraps=icons.pixel_text) as draw_text:
                    image = icons.doc_icon(text, 32)
                self.assertEqual(draw_text.call_args.args[1:],
                                 (icons.SHORT_LABELS.get(text, text), 20, 2, 2, 32))
                badges.append(image.crop((2, 19, 30, 31)).tobytes())
        self.assertEqual(len(badges), len(set(badges)))

    def test_json_short_label_has_readable_n(self):
        image = icons.doc_icon('JSON', 16)
        rows = [''.join('1' if image.getpixel((x, y)) == icons.ci.WHITE else '0'
                        for x in range(10, 14)) for y in range(10, 15)]
        self.assertEqual(rows, ['1001', '1101', '1011', '1001', '1001'])

    def test_long_labels_remain_full_at_64px(self):
        for text in icons.SHORT_LABELS:
            with self.subTest(text=text):
                with patch.object(icons, 'band', wraps=icons.band) as draw_band:
                    icons.doc_icon(text, 64)
                self.assertEqual(draw_band.call_args.args[1], text)

    def test_small_generic_has_eyes_and_beak(self):
        image = icons.doc_icon('', 16)
        self.assertEqual(image.getpixel((6, 8)), icons.ci.WHITE)
        self.assertEqual(image.getpixel((9, 8)), icons.ci.WHITE)
        self.assertEqual(image.getpixel((7, 10)), icons.ci.YEL)
        self.assertEqual(image.getpixel((7, 9)), icons.ci.NAVY)

    def test_all_sizes_use_simplified_art(self):
        with patch.object(icons.ci, 'owl', side_effect=AssertionError('full owl used')):
            for size in (16, 32, 64, 128, 256, 512):
                image = icons.doc_icon('SWIFT', size)
                self.assertEqual(image.size, (size, size))


if __name__ == '__main__':
    unittest.main()

import unittest
from unittest.mock import patch

import doc_icons as icons


class DocumentIconTests(unittest.TestCase):
    def test_small_badges_use_distinct_short_labels(self):
        labels = [icons.SHORT_LABELS.get(text, text) for text, _ in icons.TYPES if text]
        self.assertEqual(len(labels), len(set(labels)))
        self.assertTrue(all(len(label) <= 3 for label in labels))
        self.assertTrue(set(''.join(labels)) <= icons.GLYPHS.keys())
        badges = [icons.doc_icon(text, 16).crop((1, 9, 15, 16)).tobytes()
                  for text, _ in icons.TYPES if text]
        self.assertEqual(len(badges), len(set(badges)))

    def test_small_badge_glyphs_are_navy_on_coral(self):
        for text, _ in icons.TYPES:
            if not text:
                continue
            image = icons.doc_icon(text, 16)
            colors = {color for _, color in image.crop((1, 9, 15, 16)).getcolors()}
            self.assertEqual(colors, {icons.ci.NAVY, icons.ci.CORAL})

    def test_32px_art_has_tufts_round_rimmed_eyes_and_beak(self):
        image = icons.doc_icon('', 32)
        self.assertEqual(image.getpixel((9, 7)), icons.ci.NAVY)
        self.assertEqual(image.getpixel((23, 7)), icons.ci.NAVY)
        self.assertEqual(image.getpixel((11, 13)), icons.ci.WHITE)
        self.assertEqual(image.getpixel((19, 13)), icons.ci.WHITE)
        self.assertEqual(image.getpixel((13, 14)), icons.ci.NAVY)
        self.assertEqual(image.getpixel((21, 14)), icons.ci.NAVY)
        self.assertEqual(image.getpixel((16, 18)), icons.ci.YEL)

    def test_32px_badge_is_inset_with_distinct_short_labels(self):
        badges = []
        for text, _ in icons.TYPES:
            if not text:
                continue
            with patch.object(icons, 'pixel_text', wraps=icons.pixel_text) as draw_text:
                image = icons.doc_icon(text, 32)
            self.assertEqual(draw_text.call_args.args[1], icons.SHORT_LABELS.get(text, text))
            self.assertEqual(draw_text.call_args.args[3:5], (1, 1))
            coral = [x for y in range(32) for x in range(32)
                     if image.getpixel((x, y)) == icons.ci.CORAL]
            self.assertTrue(coral)
            self.assertGreater(min(coral), 5)
            self.assertLess(max(coral), 26)
            badges.append(image.crop((7, 24, 25, 29)).tobytes())
        self.assertEqual(len(badges), len(set(badges)))

    def test_64px_uses_short_pixel_labels_and_full_labels_start_at_128px(self):
        badges = []
        for text, _ in icons.TYPES:
            if not text:
                continue
            with self.subTest(text=text):
                with patch.object(icons, 'pixel_text', wraps=icons.pixel_text) as draw_text:
                    icons.doc_icon(text, 64)
                self.assertEqual(draw_text.call_args.args[1], icons.SHORT_LABELS.get(text, text))
                self.assertEqual(draw_text.call_args.args[2:5], (47, 2, 2))
                badges.append(icons.doc_icon(text, 64).crop((10, 46, 54, 59)).tobytes())
                for size in (128, 256, 512):
                    with patch.object(icons, 'band', wraps=icons.band) as draw_band:
                        icons.doc_icon(text, size)
                    self.assertEqual(draw_band.call_args.args[1], text)
        self.assertEqual(len(badges), len(set(badges)))

    def test_original_vector_owl_only_used_at_64px_and_up(self):
        with patch.object(icons.ci, 'owl', wraps=icons.ci.owl) as draw_owl:
            for size in (16, 32):
                icons.doc_icon('SWIFT', size)
            draw_owl.assert_not_called()
            icons.doc_icon('SWIFT', 64)
            self.assertEqual(draw_owl.call_count, 1)
            icons.doc_icon('SWIFT', 128)
            self.assertEqual(draw_owl.call_count, 2)

    def test_generic_32px_keeps_owl_without_coral_badge(self):
        image = icons.doc_icon('', 32)
        self.assertEqual(image.getpixel((9, 7)), icons.ci.NAVY)
        self.assertNotIn(icons.ci.CORAL, {color for _, color in image.getcolors()})


if __name__ == '__main__':
    unittest.main()

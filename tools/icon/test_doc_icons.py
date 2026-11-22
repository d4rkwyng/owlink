import unittest
from collections import defaultdict
from unittest.mock import patch

import doc_icons as icons


def visible(im, color):
    rgb = color[:3]
    return [(x, y) for y in range(im.height) for x in range(im.width)
            if im.getpixel((x, y))[3] > 128 and im.getpixel((x, y))[:3] == rgb]


def clusters_x(points, gap=3):
    if not points:
        return 0
    xs = sorted({x for x, _ in points})
    count, prev = 1, xs[0]
    for x in xs[1:]:
        if x - prev > gap:
            count += 1
        prev = x
    return count


def components(points):
    """4-connected component count."""
    remaining = set(points)
    n = 0
    while remaining:
        n += 1
        stack = [remaining.pop()]
        while stack:
            x, y = stack.pop()
            for nb in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
                if nb in remaining:
                    remaining.remove(nb)
                    stack.append(nb)
    return n


def longest_vertical_run(points):
    by_col = defaultdict(list)
    for x, y in points:
        by_col[x].append(y)
    best = 0
    for ys in by_col.values():
        ys = sorted(ys)
        run = 1
        for a, b in zip(ys, ys[1:]):
            if b == a + 1:
                run += 1
                best = max(best, run)
            else:
                run = 1
        best = max(best, run if ys else 0)
    return best


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

    def test_16px_is_page_and_badge_only(self):
        image = icons.doc_icon('', 16)
        colors = {color for _, color in image.getcolors() if color[3] > 128}
        self.assertNotIn(icons.ci.YEL, colors)
        self.assertNotIn(icons.ci.WHITE, colors)
        labeled = icons.doc_icon('MD', 16)
        self.assertIn(icons.ci.CORAL, {color for _, color in labeled.getcolors()})

    def test_cedric_pixel_32_is_the_mascot(self):
        image = icons.cedric_pixel(32)
        navy, white, yellow, chev = (visible(image, icons.ci.NAVY),
                                     visible(image, icons.ci.WHITE),
                                     visible(image, icons.ci.YEL),
                                     visible(image, icons.ci.CHEV))
        top = (image.getbbox() or (0, 0, 0, 0))[1]
        top_navy = [(x, y) for x, y in navy if y <= top + 2]
        self.assertGreaterEqual(clusters_x(top_navy, gap=4), 2, 'two ear tufts')
        self.assertGreaterEqual(components(white), 2, 'two eye discs')
        # navy pupils sit inside the white eye bounding boxes
        xs, ys = [p[0] for p in white], [p[1] for p in white]
        inner = [(x, y) for x, y in navy if min(xs) <= x <= max(xs) and min(ys) <= y <= max(ys)]
        self.assertTrue(inner, 'navy pupils')
        right_yellow = [(x, y) for x, y in yellow if x >= 16]
        self.assertTrue(right_yellow, 'monocle on the right eye')
        self.assertGreaterEqual(longest_vertical_run(right_yellow), 6, 'hanging monocle stem')
        self.assertTrue(chev, 'chest chevron')
        foot_y = max(y for _, y in yellow)
        feet = [(x, y) for x, y in yellow if y >= foot_y - 1]
        self.assertGreaterEqual(clusters_x(feet, gap=3), 2, 'two yellow feet')

    def test_cedric_pixel_64_is_the_mascot(self):
        image = icons.cedric_pixel(64)
        navy, white, yellow, chev = (visible(image, icons.ci.NAVY),
                                     visible(image, icons.ci.WHITE),
                                     visible(image, icons.ci.YEL),
                                     visible(image, icons.ci.CHEV))
        top = (image.getbbox() or (0, 0, 0, 0))[1]
        self.assertGreaterEqual(clusters_x([(x, y) for x, y in navy if y <= top + 3], gap=6), 2)
        self.assertGreaterEqual(components(white), 2, 'two eye discs')
        right_yellow = [(x, y) for x, y in yellow if x >= 32]
        self.assertGreaterEqual(longest_vertical_run(right_yellow), 10, 'monocle stem')
        self.assertTrue(chev)
        foot_y = max(y for _, y in yellow)
        self.assertGreaterEqual(clusters_x([(x, y) for x, y in yellow if y >= foot_y - 2], gap=4), 2)

    def test_32px_composited_owl_keeps_traits_and_optional_badge(self):
        generic = icons.doc_icon('', 32)
        colors = {color for _, color in generic.getcolors() if color[3] > 128}
        self.assertTrue({icons.ci.NAVY, icons.ci.WHITE, icons.ci.YEL, icons.ci.CHEV} <= colors)
        self.assertNotIn(icons.ci.CORAL, colors)
        labeled = icons.doc_icon('MD', 32)
        self.assertIn(icons.ci.CORAL, {color for _, color in labeled.getcolors()})
        # badge stays inset
        coral = [x for y in range(32) for x in range(32)
                 if labeled.getpixel((x, y)) == icons.ci.CORAL]
        self.assertTrue(coral)
        self.assertGreater(min(coral), 5)
        self.assertLess(max(coral), 26)

    def test_32px_badge_is_inset_with_distinct_short_labels(self):
        badges = []
        for text, _ in icons.TYPES:
            if not text:
                continue
            with patch.object(icons, 'pixel_text', wraps=icons.pixel_text) as draw_text:
                image = icons.doc_icon(text, 32)
            self.assertEqual(draw_text.call_args.args[1], icons.SHORT_LABELS.get(text, text))
            self.assertEqual(draw_text.call_args.args[3:5], (1, 1))
            badges.append(image.crop((7, 24, 25, 29)).tobytes())
        self.assertEqual(len(badges), len(set(badges)))

    def test_64px_uses_short_pixel_labels_and_full_labels_start_at_128px(self):
        badges = []
        for text, _ in icons.TYPES:
            if not text:
                continue
            with self.subTest(text=text):
                with patch.object(icons, 'pixel_text', wraps=icons.pixel_text) as draw_text:
                    image = icons.doc_icon(text, 64)
                self.assertEqual(draw_text.call_args.args[1], icons.SHORT_LABELS.get(text, text))
                self.assertEqual(draw_text.call_args.args[2:5], (47, 2, 2))
                badges.append(image.crop((10, 46, 54, 59)).tobytes())
                for size in (128, 256, 512):
                    with patch.object(icons, 'band', wraps=icons.band) as draw_band:
                        icons.doc_icon(text, size)
                    self.assertEqual(draw_band.call_args.args[1], text)
        self.assertEqual(len(badges), len(set(badges)))

    def test_16px_does_not_draw_the_owl(self):
        with patch.object(icons.ci, 'owl', wraps=icons.ci.owl) as draw_owl:
            icons.doc_icon('SWIFT', 16)
            draw_owl.assert_not_called()

    def test_generic_32px_keeps_owl_without_coral_badge(self):
        image = icons.doc_icon('', 32)
        colors = {color for _, color in image.getcolors() if color[3] > 128}
        self.assertIn(icons.ci.NAVY, colors)
        self.assertIn(icons.ci.YEL, colors)
        self.assertNotIn(icons.ci.CORAL, colors)


if __name__ == '__main__':
    unittest.main()

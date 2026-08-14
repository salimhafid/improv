"""Offline tests for common.py helpers. No network."""
from __future__ import annotations

import unittest
from datetime import datetime, timezone

from common import block_text, clean, local_today, parse_datetime, safe_url, strip_html


class BlockTextTests(unittest.TestCase):
    def test_preserves_paragraphs_breaks_and_bullets(self):
        from bs4 import BeautifulSoup
        html = ("<div><p>First para.</p><p>Second <br>line.</p>"
                "<ul><li>One</li><li>Two</li></ul></div>")
        el = BeautifulSoup(html, "lxml").div
        self.assertEqual(block_text(el),
                         "First para.\n\nSecond\nline.\n\n\u2022 One\n\u2022 Two")

    def test_collapses_runs_of_blank_lines(self):
        from bs4 import BeautifulSoup
        el = BeautifulSoup("<div><p>A</p><p></p><p></p><p>B</p></div>", "lxml").div
        self.assertEqual(block_text(el), "A\n\nB")


class CleanTests(unittest.TestCase):
    def test_collapses_whitespace(self):
        self.assertEqual(clean("  a \n\t b  "), "a b")

    def test_tolerates_non_strings(self):
        self.assertEqual(clean(42), "42")
        self.assertEqual(clean(["a", "b"]), "['a', 'b']")
        self.assertEqual(clean(None), "")
        self.assertEqual(clean(""), "")


class SafeUrlTests(unittest.TestCase):
    def test_allows_http_https(self):
        self.assertEqual(safe_url("https://x.test/a"), "https://x.test/a")
        self.assertEqual(safe_url("HTTP://x.test"), "HTTP://x.test")

    def test_blocks_other_schemes(self):
        self.assertEqual(safe_url("javascript:alert(1)"), "")
        self.assertEqual(safe_url("data:text/html,hi"), "")
        self.assertEqual(safe_url(None), "")
        self.assertEqual(safe_url("//protocol-relative.test"), "")


class StripHtmlTests(unittest.TestCase):
    def test_extracts_text(self):
        self.assertEqual(strip_html("<p>Hello <b>world</b></p>"), "Hello world")

    def test_tolerates_non_strings(self):
        self.assertEqual(strip_html(None), "")
        self.assertEqual(strip_html(7), "7")


class LocalTodayTests(unittest.TestCase):
    def test_evening_utc_is_still_today_in_venue_zones(self):
        # 03:17 UTC on the 22nd = 8:17pm PT / 10:17pm CT / 11:17pm ET on the 21st.
        evening = datetime(2026, 7, 22, 3, 17, tzinfo=timezone.utc)
        self.assertEqual(local_today("Los Angeles", evening).isoformat(), "2026-07-21")
        self.assertEqual(local_today("Chicago", evening).isoformat(), "2026-07-21")
        self.assertEqual(local_today("New York", evening).isoformat(), "2026-07-21")

    def test_unknown_city_falls_back_to_new_york(self):
        noon = datetime(2026, 7, 22, 12, 0, tzinfo=timezone.utc)
        self.assertEqual(local_today("Nowhere", noon), local_today("New York", noon))


class ParseDatetimeTests(unittest.TestCase):
    def test_single_datetime(self):
        start, end, has_time = parse_datetime("Friday, June 19, 2026 @ 7:00 PM")
        self.assertEqual(start, "2026-06-19T19:00:00")
        self.assertIsNone(end)
        self.assertTrue(has_time)

    def test_date_without_time(self):
        start, end, has_time = parse_datetime("June 19, 2026")
        self.assertTrue(start.startswith("2026-06-19"))
        self.assertFalse(has_time)

    def test_range_same_month(self):
        start, end, has_time = parse_datetime("Friday, June 12 - Sunday, June 14, 2026")
        self.assertEqual((start, end, has_time), ("2026-06-12", "2026-06-14", False))

    def test_range_cross_month(self):
        start, end, _ = parse_datetime("June 28 - July 2, 2026")
        self.assertEqual((start, end), ("2026-06-28", "2026-07-02"))

    def test_unparseable(self):
        self.assertEqual(parse_datetime("TBD lol"), (None, None, False))
        self.assertEqual(parse_datetime(""), (None, None, False))


if __name__ == "__main__":
    unittest.main()

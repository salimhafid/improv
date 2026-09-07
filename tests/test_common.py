"""Offline tests for common.py helpers. No network."""
from __future__ import annotations

import logging
import types
import unittest
from datetime import datetime, timezone
from unittest.mock import patch

import common
from common import (CITY_TZ, block_text, clean, fetch_html, fetch_json, local_today,
                    parse_datetime, post_json, safe_url, strip_html)


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

    def test_tolerates_non_strings_and_whitespace(self):
        # CMS fields arrive untyped; one odd value must not crash a source.
        self.assertEqual(safe_url(123), "")
        self.assertEqual(safe_url({"url": "https://x.test"}), "")
        self.assertEqual(safe_url(["https://x.test"]), "")
        self.assertEqual(safe_url("  https://x.test/a "), "https://x.test/a")


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

    def test_online_city_is_eastern(self):
        # UCB online classes are scheduled in Eastern time.
        self.assertEqual(CITY_TZ["Online"], CITY_TZ["New York"])
        evening = datetime(2026, 7, 22, 3, 17, tzinfo=timezone.utc)
        self.assertEqual(local_today("Online", evening).isoformat(), "2026-07-21")


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

    def test_trailing_end_time_is_ignored(self):
        # An added end time must not fail the parse (every UCB show undated)
        # nor be read as a UTC offset when un-spaced.
        for raw in ("Friday, June 19, 2026 @ 7:00 PM - 9:00 PM",
                    "Friday, June 19, 2026 @ 7:00 PM-9:00 PM",
                    "Friday, June 19, 2026 @ 7:00-9:00 PM"):
            self.assertEqual(parse_datetime(raw), ("2026-06-19T19:00:00", None, True), raw)

    def test_range_across_new_year_carries_the_year(self):
        # The single trailing year belongs to the end date.
        start, end, _ = parse_datetime("December 30 - January 2, 2027")
        self.assertEqual((start, end), ("2026-12-30", "2027-01-02"))

    def test_start_is_never_tz_aware(self):
        start, _, _ = parse_datetime("June 19, 2026 7:00 PM -0500")
        self.assertEqual(start, "2026-06-19T19:00:00")
        self.assertNotIn("+", start)


class _Resp:
    def __init__(self, status=200, text="", payload=None):
        self.status_code = status
        self.text = text
        self._payload = payload

    def json(self):
        if self._payload is None:
            raise ValueError("Expecting value: line 1 column 1 (char 0)")
        return self._payload


class FetchRetryTests(unittest.TestCase):
    """The shared request loop, driven by a fake curl_cffi. No network."""
    URL = "https://h.test/page"

    def setUp(self):
        common._logged_bodies.clear()
        self.sleeps: list = []
        self.calls: list = []
        # Keep the deliberate WARNINGs off the test output (assertLogs still sees them).
        self._null = logging.NullHandler()
        common.log.addHandler(self._null)
        self.addCleanup(common.log.removeHandler, self._null)

    def _run(self, responses, fn, *args):
        def request(method, url, **kw):
            self.calls.append((method, url, kw.get("impersonate"), kw.get("data")))
            r = responses.pop(0)
            if isinstance(r, Exception):
                raise r
            return r
        fake = types.SimpleNamespace(request=request)
        with patch.object(common, "cffi_requests", fake), \
             patch.object(common.time, "sleep", self.sleeps.append):
            return fn(*args)

    def test_no_sleep_after_the_final_attempt(self):
        with self.assertRaises(RuntimeError) as cm:
            self._run([_Resp(500, "boom")] * 3, fetch_html, self.URL)
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.sleeps, [1, 2])   # not [1, 2, 4]
        self.assertIn("after 3 attempts", str(cm.exception))
        self.assertEqual([c[2] for c in self.calls], ["chrome", "chrome120", "safari"])

    def test_non_retryable_statuses_short_circuit(self):
        for status in (404, 410):
            self.setUp()
            with self.assertRaises(RuntimeError) as cm:
                self._run([_Resp(status, "gone")], fetch_html, self.URL)
            self.assertEqual(len(self.calls), 1, status)
            self.assertEqual(self.sleeps, [], status)
            self.assertIn(f"status={status}", str(cm.exception))

    def test_403_rotates_to_the_next_fingerprint(self):
        # Cloudflare 403s a rejected TLS fingerprint (chrome120 on ucbcomedy.com)
        # while another passes, so a 403 must keep rotating, not short-circuit.
        got = self._run([_Resp(403, "blocked"), _Resp(200, "<html>ok</html>")], fetch_html, self.URL)
        self.assertEqual(got, "<html>ok</html>")
        self.assertEqual([c[2] for c in self.calls], ["chrome", "chrome120"])

    def test_exception_then_success_still_retries(self):
        got = self._run([ConnectionError("reset"), _Resp(200, "<html>ok</html>")], fetch_html, self.URL)
        self.assertEqual(got, "<html>ok</html>")
        self.assertEqual(self.sleeps, [1])

    def test_202_is_a_challenge_and_its_body_is_logged_once(self):
        with self.assertLogs("ucb.common", level="WARNING") as logs:
            with self.assertRaises(RuntimeError) as cm:
                self._run([_Resp(202, "<html>blocked body</html>")] * 3, fetch_html, self.URL)
        self.assertIn("status=202 challenged=True", str(cm.exception))
        bodies = [line for line in logs.output if "blocked body" in line]
        self.assertEqual(len(bodies), 1)   # once per (host, status), not per attempt
        self.assertIn("status=202", bodies[0])

    def test_challenge_page_on_200_is_retried(self):
        got = self._run([_Resp(200, "<html>Just a moment...</html>"), _Resp(200, "<html>real</html>")],
                        fetch_html, self.URL)
        self.assertEqual(got, "<html>real</html>")
        self.assertEqual(len(self.calls), 2)

    def test_fetch_json_retries_a_non_json_body(self):
        got = self._run([_Resp(200, "<html>interstitial</html>"), _Resp(200, "{}", payload={"ok": 1})],
                        fetch_json, self.URL)
        self.assertEqual(got, {"ok": 1})
        self.assertEqual(self.sleeps, [1])

    def test_post_json_sends_the_form_and_rotates_impersonation(self):
        got = self._run([_Resp(500, "x"), _Resp(200, "{}", payload={"posts": ""})],
                        post_json, self.URL, {"wpgb": "cfg"})
        self.assertEqual(got, {"posts": ""})
        self.assertEqual([c[0] for c in self.calls], ["POST", "POST"])
        self.assertEqual(self.calls[0][3], {"wpgb": "cfg"})
        self.assertEqual([c[2] for c in self.calls], ["chrome", "chrome120"])

    def test_post_json_raises_after_retries(self):
        with self.assertRaises(RuntimeError):
            self._run([_Resp(200, "<html>nope</html>")] * 3, post_json, self.URL, {"wpgb": "cfg"})
        self.assertEqual(len(self.calls), 3)


if __name__ == "__main__":
    unittest.main()

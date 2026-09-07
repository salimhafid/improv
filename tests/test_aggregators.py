"""Offline tests for the shared cadence/carry loop (aggregation.run_sources)
as driven by scraper.py and classes.py: per-source cadence, carry-over on
not-due and on failure, upcoming filtering, and summary bookkeeping. Fake
sources only — no network, tmpdir store."""
from __future__ import annotations

import os
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch

import aggregation
import classes as classes_mod
import scraper
import storage
from common import make_class, make_show

NOW = datetime(2026, 7, 22, 12, 0, 0, tzinfo=timezone.utc)


class MustNotScrape(Exception):
    """Raised by fetchers that a test expects to stay untouched. The loops
    swallow every Exception into a carry row, so the tests ALSO assert the
    mock was never called — this class just makes an accidental call show
    up by name in the error string."""


def _src(sid, fetch, *, org="Org", city="Chicago", detail=None):
    entry = {"id": sid, "org": org, "city": city, "fetch": fetch}
    if detail:
        entry["detail"] = detail
    return entry


def _show(sid, title, start):
    return make_show(title=title, start=start, url=f"https://x.test/{title}",
                     source=sid, org="Org", city="Chicago")


class AggregatorHarness(unittest.TestCase):
    """Shared tmpdir store so previous payloads round-trip like on CI."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        patcher = patch.object(storage, "LOCAL_DIR", self.tmp.name)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)
        # An exported REFRESH_DETAILS would force every source due and break
        # the cadence tests; isolate the harness from the caller's shell.
        env = patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("REFRESH_DETAILS", None)


class ScraperAggregateTests(AggregatorHarness):
    def test_fresh_scrape_and_upcoming_filter(self):
        fetch = lambda: [_show("a", "Future", "2026-07-23T20:00:00"),
                         _show("a", "Past", "2026-07-01T20:00:00")]
        with patch.object(scraper, "SOURCES", [_src("a", fetch)]):
            payload = scraper.aggregate(now=NOW)
        self.assertEqual([s["title"] for s in payload["shows"]], ["Future"])
        (summary,) = payload["sources"]
        self.assertTrue(summary["ok"])
        self.assertFalse(summary["stale"])
        self.assertEqual(summary["count"], 1)

    def test_not_due_carries_previous(self):
        prev = scraper.build_payload(
            [_show("a", "Carried", "2026-07-25T20:00:00")],
            [{"id": "a", "org": "Org", "city": "Chicago", "count": 1, "ok": True,
              "stale": False, "scraped_at": (NOW - timedelta(hours=1)).isoformat(),
              "error": None}])
        storage.save_payload(prev)
        fetch = Mock(side_effect=MustNotScrape("not due"))
        with patch.object(scraper, "SOURCES", [_src("a", fetch)]):
            payload = scraper.aggregate(now=NOW)
        fetch.assert_not_called()
        self.assertEqual([s["title"] for s in payload["shows"]], ["Carried"])
        self.assertFalse(payload["sources"][0]["stale"])
        self.assertIsNone(payload["sources"][0]["error"])

    def test_due_failure_carries_stale(self):
        prev = scraper.build_payload(
            [_show("a", "Stale but alive", "2026-07-25T20:00:00")],
            [{"id": "a", "org": "Org", "city": "Chicago", "count": 1, "ok": True,
              "stale": False, "scraped_at": (NOW - timedelta(days=2)).isoformat(),
              "error": None}])
        storage.save_payload(prev)
        def boom():
            raise RuntimeError("site down")
        with patch.object(scraper, "SOURCES", [_src("a", boom)]):
            payload = scraper.aggregate(now=NOW)
        (summary,) = payload["sources"]
        self.assertEqual(payload["shows"][0]["title"], "Stale but alive")
        self.assertTrue(summary["ok"])       # carried data keeps the source alive
        self.assertTrue(summary["stale"])    # ...but flagged stale
        self.assertEqual(summary["error"], "site down")

    def test_due_failure_with_nothing_to_carry_is_not_ok(self):
        def boom():
            raise RuntimeError("dead")
        with patch.object(scraper, "SOURCES", [_src("a", boom)]):
            payload = scraper.aggregate(now=NOW)
        (summary,) = payload["sources"]
        self.assertFalse(summary["ok"])
        self.assertEqual(payload["shows"], [])

    def test_empty_scrape_keeps_last_good_data(self):
        # A 200-OK fetch that parses to zero items must not wipe the source —
        # it's indistinguishable from a silent markup change.
        prev = scraper.build_payload(
            [_show("a", "Survivor", "2026-07-25T20:00:00")],
            [{"id": "a", "org": "Org", "city": "Chicago", "count": 1, "ok": True,
              "stale": False, "scraped_at": (NOW - timedelta(days=2)).isoformat(),
              "error": None}])
        storage.save_payload(prev)
        with patch.object(scraper, "SOURCES", [_src("a", lambda: [])]):
            payload = scraper.aggregate(now=NOW)
        (summary,) = payload["sources"]
        self.assertEqual([s["title"] for s in payload["shows"]], ["Survivor"])
        self.assertTrue(summary["stale"])
        # scraped_at unchanged so the next run retries immediately
        self.assertEqual(summary["scraped_at"], (NOW - timedelta(days=2)).isoformat())

    def test_legitimately_empty_source_publishes_empty(self):
        # No carry (e.g. wgis_ny) → an empty scrape is a real, healthy empty.
        with patch.object(scraper, "SOURCES", [_src("a", lambda: [])]):
            payload = scraper.aggregate(now=NOW)
        (summary,) = payload["sources"]
        self.assertTrue(summary["ok"])
        self.assertFalse(summary["stale"])
        self.assertEqual(summary["count"], 0)

    def test_evening_run_keeps_tonights_shows(self):
        # 03:17 UTC = 8:17pm PT the previous evening: an LA show at 9:30pm
        # that night must survive the venue-local today cut.
        evening = datetime(2026, 7, 22, 3, 17, tzinfo=timezone.utc)
        show = make_show(title="Tonight in LA", start="2026-07-21T21:30:00",
                         url="https://x.test/tonight", source="a", org="Org",
                         city="Los Angeles")
        with patch.object(scraper, "SOURCES",
                          [_src("a", lambda: [show], city="Los Angeles")]):
            payload = scraper.aggregate(now=evening)
        self.assertEqual([s["title"] for s in payload["shows"]], ["Tonight in LA"])

    def test_detail_cache_reused_without_refetch(self):
        prev_show = _show("a", "Known", "2026-07-25T20:00:00")
        prev_show["description"] = "cached desc"
        prev_show["detail_done"] = True
        prev = scraper.build_payload(
            [prev_show],
            [{"id": "a", "org": "Org", "city": "Chicago", "count": 1, "ok": True,
              "stale": False, "scraped_at": (NOW - timedelta(days=2)).isoformat(),
              "error": None}])
        storage.save_payload(prev)
        fetch = lambda: [_show("a", "Known", "2026-07-25T20:00:00")]
        detail = Mock(side_effect=MustNotScrape("detail refetched despite cache"))
        with patch.object(scraper, "SOURCES", [_src("a", fetch, detail=detail)]):
            payload = scraper.aggregate(now=NOW)
        detail.assert_not_called()
        self.assertEqual(payload["shows"][0]["description"], "cached desc")
        self.assertTrue(payload["shows"][0]["detail_done"])

    def test_detail_fills_empty_excerpt_from_description(self):
        # Sources whose listing has no blurb (Magnet) get `excerpt` from the
        # detail description; a listing-provided excerpt is left alone.
        long_desc = " ".join(f"word{i}" for i in range(60))     # > 240 chars
        fetch = lambda: [_show("a", "Blank", "2026-07-25T20:00:00"),
                         {**_show("a", "Has", "2026-07-25T21:00:00"), "excerpt": "listing"}]
        detail = lambda url: (long_desc, "", None, [])
        with patch.object(scraper, "SOURCES", [_src("a", fetch, detail=detail)]):
            payload = scraper.aggregate(now=NOW)
        by_title = {s["title"]: s for s in payload["shows"]}
        blank, has = by_title["Blank"], by_title["Has"]
        self.assertEqual(blank["description"], long_desc)
        self.assertTrue(blank["excerpt"])
        self.assertTrue(blank["excerpt"].endswith("…"))
        self.assertLessEqual(len(blank["excerpt"]), 241)
        self.assertTrue(long_desc.startswith(blank["excerpt"][:-1]))
        self.assertFalse(blank["excerpt"][:-1].endswith(" "))    # cut at a word
        self.assertEqual(has["excerpt"], "listing")
        # Also applied when a cached detail is reused (no refetch needed).
        storage.save_payload(payload)
        with patch.object(scraper, "SOURCES",
                          [_src("a", fetch, detail=Mock(side_effect=MustNotScrape()))]):
            again = scraper.aggregate(now=NOW + timedelta(days=1))
        self.assertTrue({s["title"]: s for s in again["shows"]}["Blank"]["excerpt"])
        self.assertEqual(scraper._excerpt("short one"), "short one")

    def test_detail_deadline_already_elapsed_fetches_nothing(self):
        # With the per-run deadline already past, no detail page is fetched;
        # the shows still publish, unflagged so the next run picks them up.
        fetch = lambda: [_show("a", "Late", "2026-07-25T20:00:00")]
        detail = Mock(side_effect=MustNotScrape("past the deadline"))
        with patch.object(scraper, "SOURCES", [_src("a", fetch, detail=detail)]), \
             patch.object(scraper, "_DETAIL_DEADLINE", -1):
            payload = scraper.aggregate(now=NOW)
        detail.assert_not_called()
        (show,) = payload["shows"]
        self.assertNotIn("detail_done", show)
        self.assertTrue(payload["sources"][0]["ok"])

    def test_generated_at_uses_injected_clock(self):
        with patch.object(scraper, "SOURCES", [_src("a", lambda: [])]):
            payload = scraper.aggregate(now=NOW)
        self.assertEqual(payload["generated_at"], NOW.isoformat())

    def test_refresh_details_forces_due_but_keeps_stamp_on_failure(self):
        # REFRESH_DETAILS=1 must re-scrape a source that is not due, yet a
        # source that fails on that run keeps its last-good scraped_at for
        # provenance instead of carrying None forever.
        last = (NOW - timedelta(hours=1)).isoformat()
        prev = scraper.build_payload(
            [_show("a", "Carried", "2026-07-25T20:00:00")],
            [{"id": "a", "org": "Org", "city": "Chicago", "count": 1, "ok": True,
              "stale": False, "scraped_at": last, "error": None}])
        storage.save_payload(prev)
        fetch = Mock(side_effect=RuntimeError("site down"))
        os.environ["REFRESH_DETAILS"] = "1"
        with patch.object(scraper, "SOURCES", [_src("a", fetch)]):
            payload = scraper.aggregate(now=NOW)
        fetch.assert_called_once()
        (summary,) = payload["sources"]
        self.assertTrue(summary["stale"])
        self.assertEqual(summary["scraped_at"], last)
        self.assertEqual([s["title"] for s in payload["shows"]], ["Carried"])

    def test_corrupt_carried_row_is_dropped_not_fatal(self):
        # A non-dict row in the previous payload (hand edit, partial write)
        # must be dropped from the carry, not abort the whole run.
        prev = scraper.build_payload(
            [_show("a", "Fine", "2026-07-25T20:00:00")],
            [{"id": "a", "org": "Org", "city": "Chicago", "count": 1, "ok": True,
              "stale": False, "scraped_at": (NOW - timedelta(hours=1)).isoformat(),
              "error": None}])
        prev["shows"].append("not a show")
        storage.save_payload(prev)
        with patch.object(scraper, "SOURCES", [_src("a", Mock(side_effect=MustNotScrape()))]):
            payload = scraper.aggregate(now=NOW)
        self.assertEqual([s["title"] for s in payload["shows"]], ["Fine"])
        self.assertEqual(payload["sources"][0]["count"], 1)


class DetailEnrichmentTests(unittest.TestCase):
    def test_deadline_stops_new_fetches_and_leaves_rest_unflagged(self):
        # One worker, a detail page that hangs past the deadline: the first
        # fetch (started in time) lands, the queued ones are skipped and stay
        # unflagged/uncached so the next run retries them.
        calls = []
        def slow_detail(url):
            calls.append(url)
            time.sleep(0.2)
            return (f"desc {url}", "", None, [])
        shows = [_show("a", f"S{i}", "2026-07-25T20:00:00") for i in range(3)]
        prev_detail = {}
        with patch.object(scraper, "_DETAIL_WORKERS", 1):
            attempted = scraper._enrich_details(shows, slow_detail, prev_detail, 400,
                                                deadline=time.monotonic() + 0.05)
        self.assertEqual(attempted, 1)
        self.assertEqual(calls, [shows[0]["url"]])
        self.assertTrue(shows[0]["detail_done"])
        self.assertEqual(shows[0]["description"], f"desc {shows[0]['url']}")
        for s in shows[1:]:
            self.assertNotIn("detail_done", s)
            self.assertEqual(s["description"], "")
        self.assertEqual(set(prev_detail), {shows[0]["url"]})

    def test_no_deadline_fetches_everything(self):
        shows = [_show("a", f"S{i}", "2026-07-25T20:00:00") for i in range(3)]
        n = scraper._enrich_details(shows, lambda u: ("d", "", None, []), {}, 400)
        self.assertEqual(n, 3)
        self.assertTrue(all(s["detail_done"] for s in shows))


class RunSourcesTests(unittest.TestCase):
    def test_carried_item_keep_cannot_judge_is_dropped_not_fatal(self):
        # keep() blowing up on one malformed carried row must drop that row
        # and keep the rest, never abort the run before any feed is saved.
        def keep(item, today):
            if item.get("start") == "garbage":
                raise ValueError("unparseable")
            return True
        prev = {"a": [{"title": "Fine", "start": "2026-07-25"},
                      {"title": "Bad", "start": "garbage"}]}
        fetch = Mock(side_effect=MustNotScrape("not due"))
        items, summary = aggregation.run_sources(
            [_src("a", fetch)], previous_items=prev,
            prev_scraped={"a": (NOW - timedelta(hours=1)).isoformat()}, now=NOW,
            intervals={}, default_interval=24 * 3600, grace=1800, keep=keep)
        fetch.assert_not_called()
        self.assertEqual([x["title"] for x in items], ["Fine"])
        self.assertEqual(summary[0]["count"], 1)


class ClassesAggregateTests(AggregatorHarness):
    def test_daily_cadence_and_undated_kept(self):
        fetch = lambda: [make_class(id="x/1", title="Dated", start="2026-08-01",
                                    source="x", org="O", city="Chicago"),
                         make_class(id="x/2", title="Undated",
                                    source="x", org="O", city="Chicago"),
                         make_class(id="x/3", title="Ended", start="2026-07-01",
                                    source="x", org="O", city="Chicago")]
        with patch.object(classes_mod, "CLASS_SOURCES",
                          [{"id": "x", "org": "O", "city": "Chicago", "fetch": fetch}]):
            payload = classes_mod.aggregate_classes(now=NOW)
        self.assertEqual(sorted(c["title"] for c in payload["classes"]),
                         ["Dated", "Undated"])

    def test_not_due_carries(self):
        prev = {"generated_at": NOW.isoformat(), "count": 1,
                "sources": [{"id": "x", "org": "O", "city": "Chicago", "count": 1,
                             "ok": True, "stale": False,
                             "scraped_at": (NOW - timedelta(hours=2)).isoformat(),
                             "error": None}],
                "classes": [make_class(id="x/1", title="Carried", start="2026-08-01",
                                       source="x", org="O", city="Chicago")]}
        storage.save_classes(prev)
        fetch = Mock(side_effect=MustNotScrape("not due"))
        with patch.object(classes_mod, "CLASS_SOURCES",
                          [{"id": "x", "org": "O", "city": "Chicago", "fetch": fetch}]):
            payload = classes_mod.aggregate_classes(now=NOW)
        fetch.assert_not_called()
        self.assertEqual([c["title"] for c in payload["classes"]], ["Carried"])
        self.assertEqual(payload["generated_at"], NOW.isoformat())

    def test_null_title_does_not_break_sort(self):
        # Two classes sharing a start where one has a present-but-null title
        # used to raise TypeError in the sort tie-break and abort the run.
        fetch = lambda: [make_class(id="x/1", title="B", start="2026-08-01",
                                    source="x", org="O", city="Chicago"),
                         {**make_class(id="x/2", title="A", start="2026-08-01",
                                       source="x", org="O", city="Chicago"), "title": None}]
        with patch.object(classes_mod, "CLASS_SOURCES",
                          [{"id": "x", "org": "O", "city": "Chicago", "fetch": fetch}]):
            payload = classes_mod.aggregate_classes(now=NOW)
        self.assertEqual([c["title"] for c in payload["classes"]], [None, "B"])


if __name__ == "__main__":
    unittest.main()

"""Offline tests for the aggregation loops (scraper.py / classes.py):
per-source cadence, carry-over on not-due and on failure, upcoming filtering,
and summary bookkeeping. Fake sources only — no network, tmpdir store."""
from __future__ import annotations

import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone
from unittest.mock import patch

import classes as classes_mod
import scraper
import storage
from common import make_class, make_show

NOW = datetime(2026, 7, 22, 12, 0, 0, tzinfo=timezone.utc)
TODAY = date(2026, 7, 22)


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
        boom = lambda: (_ for _ in ()).throw(AssertionError("must not scrape"))
        with patch.object(scraper, "SOURCES", [_src("a", boom)]):
            payload = scraper.aggregate(now=NOW)
        self.assertEqual([s["title"] for s in payload["shows"]], ["Carried"])
        self.assertFalse(payload["sources"][0]["stale"])

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
        def never_called(url):
            raise AssertionError("detail refetched despite cache")
        with patch.object(scraper, "SOURCES", [_src("a", fetch, detail=never_called)]):
            payload = scraper.aggregate(now=NOW)
        self.assertEqual(payload["shows"][0]["description"], "cached desc")
        self.assertTrue(payload["shows"][0]["detail_done"])


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
        boom = lambda: (_ for _ in ()).throw(AssertionError("must not scrape"))
        with patch.object(classes_mod, "CLASS_SOURCES",
                          [{"id": "x", "org": "O", "city": "Chicago", "fetch": boom}]):
            payload = classes_mod.aggregate_classes(now=NOW)
        self.assertEqual([c["title"] for c in payload["classes"]], ["Carried"])


if __name__ == "__main__":
    unittest.main()

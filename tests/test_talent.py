"""Offline tests for the talent aggregator (talent.py): per-group cadence
stamps with grace, carry-over on not-due and on failure, the outright-failure
back-off, the shrink guard, tolerance of malformed previous rows, and the
lazy bio budget. Fake fetchers only — no network, tmpdir store."""
from __future__ import annotations

import os
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch

import storage
import talent

NOW = datetime(2026, 7, 22, 12, 0, 0, tzinfo=timezone.utc)
PAGES = [("ny", "https://x.test/ny"), ("la", "https://x.test/la"),
         ("teachers", "https://x.test/teachers")]


class MustNotFetch(Exception):
    """Raised by fetchers a test expects to stay untouched; the loop swallows
    every Exception into a carry row, so tests also assert_not_called()."""


def _person(slug, *groups, **extra):
    return {"name": slug.title(), "slug": slug, "url": f"https://x.test/people/{slug}/",
            "image": None, "groups": list(groups), "bio": "", "bio_done": True, **extra}


def _page_person(slug, dcm=False):
    return {"name": slug.title(), "slug": slug, "url": f"https://x.test/people/{slug}/",
            "image": None, "dcm": dcm}


def _row(group, scraped_at, **extra):
    return {"id": group, "org": "UCB", "city": "", "count": 1, "ok": True,
            "stale": False, "scraped_at": scraped_at, "error": None, **extra}


def _previous(people, stamps, **top):
    """A previous talent.json with per-group stamps (None = never scraped)."""
    return {"generated_at": NOW.isoformat(), "roster_scraped_at": max(filter(None, stamps.values()), default=None),
            "roster_attempted_at": None, "count": len(people),
            "sources": [_row(g, st) for g, st in stamps.items()], "people": people, **top}


class TalentHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        p = patch.object(storage, "LOCAL_DIR", self.tmp.name)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("TALENT_BIO_BUDGET", None)
        # Default fetchers: every page/roster answers, bios are empty strings.
        self.pages = {url: [_page_person(f"{g}1"), _page_person(f"{g}2")] for g, url in PAGES}
        self.fetch_page = Mock(side_effect=lambda url: [dict(p) for p in self.pages[url]])
        self.fetch_dcm = Mock(return_value=[_page_person("dcm1"), _page_person("dcm2")])
        self.bio = Mock(return_value="")
        for name, value in (("PAGES", PAGES), ("fetch_page", self.fetch_page),
                            ("fetch_dcm_roster", self.fetch_dcm), ("bio", self.bio)):
            p = patch.object(talent, name, value)
            p.start()
            self.addCleanup(p.stop)

    def run_at(self, when=NOW):
        payload = talent.aggregate_talent(now=when)
        storage.save_talent(payload)
        return payload

    @staticmethod
    def rows(payload):
        return {s["id"]: s for s in payload["sources"]}


class TalentSweepTests(TalentHarness):
    def test_first_run_sweeps_every_group_with_uniform_rows(self):
        payload = self.run_at()
        self.assertEqual(self.fetch_page.call_count, 3)
        self.fetch_dcm.assert_called_once()
        rows = self.rows(payload)
        self.assertEqual(set(rows), {"ny", "la", "teachers", "dcm"})
        for row in rows.values():
            # Same shape as show/class summary rows so probe runs read uniformly.
            self.assertEqual(set(row), {"id", "org", "city", "count", "ok", "stale",
                                        "scraped_at", "error"})
            self.assertEqual(row["scraped_at"], NOW.isoformat())
            self.assertFalse(row["stale"])
            self.assertIsNone(row["error"])
        self.assertEqual(rows["ny"]["city"], "New York")
        self.assertEqual(payload["roster_scraped_at"], NOW.isoformat())
        self.assertEqual(payload["roster_attempted_at"], NOW.isoformat())
        self.assertEqual(payload["count"], 8)

    def test_only_due_groups_are_fetched(self):
        stale = (NOW - timedelta(hours=25)).isoformat()
        fresh = (NOW - timedelta(hours=2)).isoformat()
        storage.save_talent(_previous(
            [_person("ny1", "ny"), _person("la1", "la"), _person("t1", "teachers"),
             _person("dcm1", "dcm")],
            {"ny": stale, "la": fresh, "teachers": fresh, "dcm": fresh}))
        self.fetch_dcm.side_effect = MustNotFetch("dcm not due")
        payload = self.run_at()
        self.fetch_page.assert_called_once_with("https://x.test/ny")
        rows = self.rows(payload)
        self.assertEqual(rows["ny"]["scraped_at"], NOW.isoformat())
        for g in ("la", "teachers", "dcm"):
            self.assertEqual(rows[g]["scraped_at"], fresh)
            self.assertFalse(rows[g]["stale"])
            self.assertIsNone(rows[g]["error"])
            self.assertEqual(rows[g]["count"], 1)
        slugs = {p["slug"]: p["groups"] for p in payload["people"]}
        self.assertEqual(slugs["la1"], ["la"])
        self.assertEqual(sorted(slugs), ["dcm1", "la1", "ny1", "ny2", "t1"])

    def test_grace_window_lets_an_early_tick_count(self):
        just_short = (NOW - timedelta(hours=23, minutes=45)).isoformat()
        storage.save_talent(_previous([_person("ny1", "ny")],
                                      {"ny": just_short, "la": just_short,
                                       "teachers": just_short, "dcm": just_short}))
        self.run_at()
        self.assertEqual(self.fetch_page.call_count, 3)
        self.fetch_dcm.assert_called_once()

    def test_nothing_due_makes_no_requests_and_keeps_people(self):
        fresh = (NOW - timedelta(hours=1)).isoformat()
        storage.save_talent(_previous([_person("ny1", "ny", "dcm", bio="hi")],
                                      {"ny": fresh, "la": fresh, "teachers": fresh, "dcm": fresh}))
        self.fetch_page.side_effect = MustNotFetch()
        self.fetch_dcm.side_effect = MustNotFetch()
        payload = self.run_at()
        self.fetch_page.assert_not_called()
        self.fetch_dcm.assert_not_called()
        self.bio.assert_not_called()
        (person,) = payload["people"]
        self.assertEqual(person["bio"], "hi")
        self.assertEqual(sorted(person["groups"]), ["dcm", "ny"])
        self.assertEqual(payload["roster_attempted_at"], None)
        self.assertEqual(payload["roster_scraped_at"], fresh)

    def test_never_scraped_group_stays_due_while_others_are_fresh(self):
        # A new-format row with an explicit scraped_at=None (the group has
        # never succeeded) must not inherit the roster clock from the groups
        # that did scrape — it is retried on the next tick.
        fresh = (NOW - timedelta(hours=1)).isoformat()
        storage.save_talent(_previous([_person("la1", "la"), _person("dcm1", "dcm")],
                                      {"ny": None, "la": fresh, "teachers": fresh, "dcm": fresh},
                                      roster_attempted_at=fresh))
        self.fetch_dcm.side_effect = MustNotFetch("dcm not due")
        payload = self.run_at()
        self.fetch_page.assert_called_once_with("https://x.test/ny")
        self.fetch_dcm.assert_not_called()
        self.assertEqual(self.rows(payload)["ny"]["scraped_at"], NOW.isoformat())

    def test_legacy_payload_without_row_stamps_uses_roster_clock(self):
        old = (NOW - timedelta(hours=30)).isoformat()
        storage.save_talent({"generated_at": old, "roster_scraped_at": old, "count": 1,
                             "sources": [{"id": "ny", "count": 1, "ok": True, "error": None}],
                             "people": [_person("ny1", "ny")]})
        self.assertTrue(talent._group_due(talent._prev_stamps(storage.load_talent())["ny"], NOW))
        self.run_at()
        self.assertEqual(self.fetch_page.call_count, 3)


class TalentFailureTests(TalentHarness):
    def test_failed_group_carries_stale_and_stays_due(self):
        stale = (NOW - timedelta(hours=25)).isoformat()
        storage.save_talent(_previous(
            [_person("ny1", "ny"), _person("la1", "la"), _person("t1", "teachers"),
             _person("dcm1", "dcm")],
            {"ny": stale, "la": stale, "teachers": stale, "dcm": stale}))
        self.fetch_page.side_effect = lambda url: (
            (_ for _ in ()).throw(RuntimeError("202")) if url.endswith("/ny") else [_page_person("x")])
        payload = self.run_at()
        rows = self.rows(payload)
        self.assertTrue(rows["ny"]["stale"])
        self.assertTrue(rows["ny"]["ok"])            # carried data keeps the group alive
        self.assertEqual(rows["ny"]["error"], "202")
        self.assertEqual(rows["ny"]["scraped_at"], stale)   # unchanged → retried next run
        self.assertEqual(rows["la"]["scraped_at"], NOW.isoformat())
        self.assertEqual(payload["roster_scraped_at"], NOW.isoformat())
        self.assertIn("ny1", {p["slug"] for p in payload["people"]})
        # A partially successful sweep does not back off: ny is retried on the
        # next tick while la/teachers/dcm wait out their day.
        later = NOW + timedelta(hours=3)
        self.fetch_page.reset_mock()
        self.fetch_dcm.reset_mock()
        self.fetch_dcm.side_effect = MustNotFetch()
        self.run_at(later)
        self.fetch_page.assert_called_once_with("https://x.test/ny")
        self.fetch_dcm.assert_not_called()

    def test_outright_failure_backs_off_six_hours(self):
        stale = (NOW - timedelta(hours=25)).isoformat()
        storage.save_talent(_previous(
            [_person("ny1", "ny"), _person("dcm1", "dcm")],
            {"ny": stale, "la": stale, "teachers": stale, "dcm": stale}))
        self.fetch_page.side_effect = RuntimeError("202")
        self.fetch_dcm.side_effect = RuntimeError("Expecting value")
        payload = self.run_at()
        self.assertEqual(self.fetch_page.call_count, 3)
        self.assertEqual(payload["roster_scraped_at"], stale)
        self.assertEqual(payload["roster_attempted_at"], NOW.isoformat())
        self.assertEqual([p["slug"] for p in payload["people"]], ["dcm1", "ny1"])
        # 3h later: still inside the back-off, not a single request.
        self.fetch_page.reset_mock()
        self.fetch_dcm.reset_mock()
        payload = self.run_at(NOW + timedelta(hours=3))
        self.fetch_page.assert_not_called()
        self.fetch_dcm.assert_not_called()
        self.assertEqual(payload["roster_attempted_at"], NOW.isoformat())
        self.assertEqual([p["slug"] for p in payload["people"]], ["dcm1", "ny1"])
        rows = self.rows(payload)
        self.assertFalse(rows["ny"]["stale"])   # a carried-by-cadence row, no error
        self.assertIsNone(rows["ny"]["error"])
        # 6h later: retried, and a success clears the back-off.
        self.fetch_page.side_effect = lambda url: [_page_person("fresh")]
        self.fetch_dcm.side_effect = None
        payload = self.run_at(NOW + timedelta(hours=6))
        self.assertEqual(self.fetch_page.call_count, 3)
        self.assertEqual(payload["roster_scraped_at"], (NOW + timedelta(hours=6)).isoformat())
        self.assertFalse(talent._backing_off(payload, NOW + timedelta(hours=9)))

    def test_backoff_after_first_ever_failed_sweep(self):
        # No previous payload at all: a totally failed first sweep still
        # records the attempt so the next tick does not hammer the host.
        self.fetch_page.side_effect = RuntimeError("202")
        self.fetch_dcm.side_effect = RuntimeError("202")
        payload = self.run_at()
        self.assertIsNone(payload["roster_scraped_at"])
        self.assertTrue(all(not s["ok"] for s in payload["sources"]))
        self.assertTrue(talent._backing_off(payload, NOW + timedelta(hours=3)))
        self.assertFalse(talent._backing_off(payload, NOW + timedelta(hours=6)))

    def test_shrunken_page_is_treated_as_failed(self):
        stale = (NOW - timedelta(hours=25)).isoformat()
        prev = [_person(f"ny{i}", "ny") for i in range(10)]
        storage.save_talent(_previous(prev, {"ny": stale, "la": stale,
                                             "teachers": stale, "dcm": stale}))
        self.pages["https://x.test/ny"] = [_page_person("ny0"), _page_person("ny1")]
        payload = self.run_at()
        rows = self.rows(payload)
        self.assertTrue(rows["ny"]["stale"])
        self.assertIn("parsed 2 people vs 10", rows["ny"]["error"])
        self.assertEqual(rows["ny"]["count"], 10)
        self.assertEqual(rows["ny"]["scraped_at"], stale)
        # A modest change (7 of 10) is a real roster edit and goes through.
        self.pages["https://x.test/ny"] = [_page_person(f"ny{i}") for i in range(7)]
        payload = self.run_at(NOW + timedelta(hours=3))
        self.assertEqual(self.rows(payload)["ny"]["count"], 7)
        self.assertFalse(self.rows(payload)["ny"]["stale"])

    def test_malformed_previous_rows_are_skipped_not_fatal(self):
        fresh = (NOW - timedelta(hours=1)).isoformat()
        people = [_person("ny1", "ny"), {"name": "No Slug", "groups": ["ny"]},
                  "not a person", {"slug": "no-url", "groups": ["ny"]}]
        storage.save_talent(_previous(people, {"ny": fresh, "la": fresh,
                                               "teachers": fresh, "dcm": fresh}))
        self.bio.side_effect = KeyError("url")   # would escape ex.map without safe()
        payload = self.run_at()
        slugs = [p.get("slug") for p in payload["people"]]
        self.assertEqual(slugs, ["no-url", "ny1"])
        self.assertEqual(self.rows(payload)["ny"]["count"], 2)


class BioBudgetTests(TalentHarness):
    def test_budget_env_is_lazy_and_tolerant(self):
        self.assertEqual(talent._bio_budget(), talent._DEFAULT_BIO_BUDGET)
        os.environ["TALENT_BIO_BUDGET"] = "abc"
        self.assertEqual(talent._bio_budget(), talent._DEFAULT_BIO_BUDGET)
        os.environ["TALENT_BIO_BUDGET"] = " "
        self.assertEqual(talent._bio_budget(), talent._DEFAULT_BIO_BUDGET)
        os.environ["TALENT_BIO_BUDGET"] = "2"
        self.assertEqual(talent._bio_budget(), 2)

    def test_deadline_stops_new_fetches_and_leaves_rest_unflagged(self):
        calls = []
        def slow_bio(url):
            calls.append(url)
            time.sleep(0.2)
            return "bio"
        self.bio.side_effect = slow_bio
        people = [{"slug": s, "url": f"u/{s}"} for s in ("a", "b", "c")]
        with patch.object(talent, "_BIO_WORKERS", 1):
            attempted = talent._enrich_bios(people, [], deadline=time.monotonic() + 0.05)
        self.assertEqual(attempted, 1)
        self.assertEqual(calls, ["u/a"])
        self.assertEqual(people[0]["bio"], "bio")
        self.assertTrue(people[0]["bio_done"])
        for p in people[1:]:
            self.assertNotIn("bio_done", p)    # retried next run

    def test_elapsed_deadline_via_aggregate_fetches_no_bios(self):
        self.bio.side_effect = MustNotFetch("past the deadline")
        with patch.object(talent, "_BIO_DEADLINE", -1):
            payload = self.run_at()
        self.bio.assert_not_called()
        self.assertEqual(payload["count"], 8)
        self.assertTrue(all("bio_done" not in p for p in payload["people"]))

    def test_budget_caps_fetches_and_failed_fetch_retries(self):
        os.environ["TALENT_BIO_BUDGET"] = "1"
        self.bio.return_value = None   # fetch failed
        people = [{"slug": "a", "url": "u/a"}, {"slug": "b", "url": "u/b"}]
        self.assertEqual(talent._enrich_bios(people, []), 1)
        self.bio.assert_called_once_with("u/a")
        self.assertNotIn("bio_done", people[0])   # retried next run
        self.bio.return_value = "text"
        prev = [{"slug": "b", "bio": "cached", "bio_done": True}]
        talent._enrich_bios(people, prev)
        self.assertEqual(people[1]["bio"], "cached")
        self.assertEqual(people[0]["bio"], "text")


if __name__ == "__main__":
    unittest.main()

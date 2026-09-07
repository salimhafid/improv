"""Offline tests for publish_static.py's guards and exit code, and for
storage.save's failure path. The aggregators are stubbed; tmpdir store."""
from __future__ import annotations

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

import publish_static
import storage


def _row(sid, count, ok=True, stale=False):
    return {"id": sid, "org": "O", "city": "Chicago", "count": count, "ok": ok,
            "stale": stale, "scraped_at": None, "error": None}


def _payload(key, items, rows):
    return {"generated_at": "2026-07-22T12:00:00+00:00", "count": len(items),
            "sources": rows, key: items}


class PublishHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = patch.object(storage, "LOCAL_DIR", self.tmp.name)
        p.start()
        self.addCleanup(p.stop)
        self.shows = _payload("shows", [{"title": "A"}], [_row("a", 1)])
        self.classes = _payload("classes", [{"title": "C"}], [_row("x", 1)])
        self.talent = _payload("people", [{"slug": "p"}], [_row("ny", 1)])

    def run_main(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(publish_static, "scrape", lambda: self.shows), \
             patch.object(publish_static, "aggregate_classes", lambda: self.classes), \
             patch.object(publish_static, "aggregate_talent", lambda: self.talent), \
             redirect_stdout(out), redirect_stderr(err):
            code = publish_static.main()
        return code, err.getvalue()

    def stored(self, name):
        path = os.path.join(self.tmp.name, name)
        if not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as f:
            return json.load(f)


class PublishTests(PublishHarness):
    def test_happy_path_writes_all_three_and_exits_zero(self):
        code, _ = self.run_main()
        self.assertEqual(code, 0)
        for name in (storage.SHOWS_BLOB, storage.CLASSES_BLOB, storage.TALENT_BLOB):
            self.assertIsNotNone(self.stored(name))

    def test_failed_save_exits_nonzero(self):
        # storage.save turns any exception into False; main must not report
        # success (and leave the old feed behind a green run) when that happens.
        self.shows["shows"][0]["when"] = {1, 2}   # a set is not JSON-serialisable
        code, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("could not write shows", err)
        self.assertIsNone(self.stored(storage.SHOWS_BLOB))
        self.assertIsNotNone(self.stored(storage.CLASSES_BLOB))   # the others still publish

    def test_unset_store_dir_exits_nonzero(self):
        with patch.object(storage, "LOCAL_DIR", ""):
            code, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("LOCAL_STORE_DIR", err)

    def test_legitimately_empty_ok_source_cannot_vouch_for_an_empty_feed(self):
        # wgis_ny answers ok=True/count=0 every run; with every other source
        # failed and nothing to carry, that must not publish an empty feed.
        storage.save_payload(self.shows)
        self.shows = _payload("shows", [], [_row("wgis_ny", 0), _row("ucb_ny", 0, ok=False)])
        code, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("refusing to publish", err)
        self.assertEqual(self.stored(storage.SHOWS_BLOB)["count"], 1)   # previous file intact
        self.assertIsNone(self.stored(storage.CLASSES_BLOB))            # nothing else written

    def test_carried_stale_source_still_publishes(self):
        self.shows = _payload("shows", [{"title": "Old"}], [_row("a", 1, stale=True)])
        code, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertEqual(self.stored(storage.SHOWS_BLOB)["shows"], [{"title": "Old"}])

    def test_empty_classes_or_talent_keeps_previous_file_without_failing(self):
        storage.save_classes(self.classes)
        self.classes = _payload("classes", [], [_row("wgis_ny", 0), _row("x", 0, ok=False)])
        self.talent = _payload("people", [], [_row("ny", 0, ok=False)])
        code, err = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("classes: no source contributed items", err)
        self.assertIn("talent: no source contributed items", err)
        self.assertEqual(self.stored(storage.CLASSES_BLOB)["count"], 1)
        self.assertIsNone(self.stored(storage.TALENT_BLOB))


class StorageSaveTests(PublishHarness):
    def test_failed_write_cleans_tmp_and_keeps_previous(self):
        self.assertTrue(storage.save_payload(self.shows))
        bad = dict(self.shows, shows=[{"when": {1}}])
        self.assertFalse(storage.save_payload(bad))
        self.assertEqual(sorted(os.listdir(self.tmp.name)), [storage.SHOWS_BLOB])
        self.assertEqual(self.stored(storage.SHOWS_BLOB)["count"], 1)


if __name__ == "__main__":
    unittest.main()

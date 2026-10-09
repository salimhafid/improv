"""Offline tests for publish_static.py's guards and exit code, its
--classes-only mode and WATCH_STATE_FILE handling, and for storage.save's
failure path. The aggregators are stubbed; tmpdir store."""
from __future__ import annotations

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import Mock, patch

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
        # An exported WATCH_STATE_FILE would leak the caller's state into
        # every run; isolate the harness from the caller's shell.
        env = patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("WATCH_STATE_FILE", None)
        self.shows = _payload("shows", [{"title": "A"}], [_row("a", 1)])
        self.classes = _payload("classes", [{"title": "C"}], [_row("x", 1)])
        self.talent = _payload("people", [{"slug": "p"}], [_row("ny", 1)])
        self.class_calls = []    # the watch_state each aggregate_classes call got

    def aggregate_classes(self, **kwargs):
        self.class_calls.append(kwargs.get("watch_state"))
        return self.classes

    def run_main(self, argv=(), *, scrape=None, talent=None):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(publish_static, "scrape", scrape or (lambda: self.shows)), \
             patch.object(publish_static, "aggregate_classes", self.aggregate_classes), \
             patch.object(publish_static, "aggregate_talent", talent or (lambda: self.talent)), \
             redirect_stdout(out), redirect_stderr(err):
            code = publish_static.main(list(argv))
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


class ClassesOnlyTests(PublishHarness):
    """--classes-only: the class watcher's dispatched refresh. It must never
    touch shows.json or talent.json (nor spend their scrape time)."""

    def run_classes_only(self):
        must_not_run = Mock(side_effect=AssertionError("must not run in --classes-only"))
        code, err = self.run_main(["--classes-only"], scrape=must_not_run, talent=must_not_run)
        must_not_run.assert_not_called()
        return code, err

    def test_saves_classes_and_leaves_shows_and_talent_untouched(self):
        storage.save_payload(_payload("shows", [{"title": "Old show"}], [_row("a", 1)]))
        storage.save_talent(_payload("people", [{"slug": "old"}], [_row("ny", 1)]))
        shows_before = self.stored(storage.SHOWS_BLOB)
        talent_before = self.stored(storage.TALENT_BLOB)
        code, _ = self.run_classes_only()
        self.assertEqual(code, 0)
        self.assertEqual(self.stored(storage.CLASSES_BLOB), self.classes)
        self.assertEqual(self.stored(storage.SHOWS_BLOB), shows_before)
        self.assertEqual(self.stored(storage.TALENT_BLOB), talent_before)

    def test_does_not_create_missing_shows_or_talent_files(self):
        code, _ = self.run_classes_only()
        self.assertEqual(code, 0)
        self.assertEqual(sorted(os.listdir(self.tmp.name)), [storage.CLASSES_BLOB])

    def test_failed_classes_write_exits_nonzero(self):
        self.classes["classes"][0]["when"] = {1}     # not JSON-serialisable
        code, err = self.run_classes_only()
        self.assertEqual(code, 1)
        self.assertIn("could not write classes", err)

    def test_unset_store_dir_exits_nonzero(self):
        with patch.object(storage, "LOCAL_DIR", ""):
            code, err = self.run_classes_only()
        self.assertEqual(code, 1)
        self.assertIn("LOCAL_STORE_DIR", err)

    def test_empty_classes_keeps_previous_file_without_failing(self):
        storage.save_classes(self.classes)
        self.classes = _payload("classes", [], [_row("x", 0, ok=False)])
        code, err = self.run_classes_only()
        self.assertEqual(code, 0)
        self.assertIn("classes: no source contributed items", err)
        self.assertEqual(self.stored(storage.CLASSES_BLOB)["count"], 1)


class WatchStateFileTests(PublishHarness):
    """WATCH_STATE_FILE only lets class sources refresh early, so every
    problem with it degrades to "no state" with a warning, never a failed
    publish."""

    def write_state(self, data: bytes):
        path = os.path.join(self.tmp.name, "class-watch.json")
        with open(path, "wb") as f:
            f.write(data)
        os.environ["WATCH_STATE_FILE"] = path

    def test_state_is_passed_to_classes_in_both_modes(self):
        state = {"ucb_ny": {"ids": ["1"], "updated": "2026-10-09T22:00:00+00:00",
                            "new_at": "2026-10-09T22:00:00+00:00"}}
        self.write_state(json.dumps(state).encode())
        for argv in ([], ["--classes-only"]):
            with self.subTest(argv=argv):
                self.class_calls.clear()
                code, err = self.run_main(argv)
                self.assertEqual(code, 0)
                self.assertEqual(self.class_calls, [state])
                self.assertNotIn("WATCH_STATE_FILE", err)

    def test_unset_or_empty_env_is_silently_no_state(self):
        for value in (None, ""):
            with self.subTest(value=value):
                self.class_calls.clear()
                if value is not None:
                    os.environ["WATCH_STATE_FILE"] = value
                code, err = self.run_main()
                self.assertEqual(code, 0)
                self.assertEqual(self.class_calls, [None])
                self.assertNotIn("WATCH_STATE_FILE", err)

    def test_missing_corrupt_or_non_object_file_warns_and_publishes_without_state(self):
        for label, data in (("missing", None), ("corrupt", b'{"ucb_ny": {"new_at": '),
                            ("not utf-8", b"\xff\xfe{"), ("not an object", b'["ucb_ny"]')):
            for argv in ([], ["--classes-only"]):
                with self.subTest(label=label, argv=argv):
                    self.class_calls.clear()
                    if data is None:
                        os.environ["WATCH_STATE_FILE"] = os.path.join(
                            self.tmp.name, "absent", "class-watch.json")
                    else:
                        self.write_state(data)
                    code, err = self.run_main(argv)
                    self.assertEqual(code, 0)
                    self.assertEqual(self.class_calls, [None])
                    self.assertIn("WATCH_STATE_FILE", err)
                    self.assertIn("normal cadence", err)
                    self.assertIsNotNone(self.stored(storage.CLASSES_BLOB))


class StorageSaveTests(PublishHarness):
    def test_failed_write_cleans_tmp_and_keeps_previous(self):
        self.assertTrue(storage.save_payload(self.shows))
        bad = dict(self.shows, shows=[{"when": {1}}])
        self.assertFalse(storage.save_payload(bad))
        self.assertEqual(sorted(os.listdir(self.tmp.name)), [storage.SHOWS_BLOB])
        self.assertEqual(self.stored(storage.SHOWS_BLOB)["count"], 1)


if __name__ == "__main__":
    unittest.main()

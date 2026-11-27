"""Exercise the post-publish check using the summary rows the app consumes."""
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from tools.check_ucb_feeds import check_feed


CHECK = Path(__file__).resolve().parents[1] / "tools" / "check_ucb_feeds.py"


class UCBFeedHealthTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.now = datetime.now(timezone.utc)
        self.stamp = self.now.isoformat()
        self.classes = self.summaries("ucb_ny", "ucb_la", "ucb_online")
        self.shows = self.summaries("ucb_ny", "ucb_la")

    def summaries(self, *schools):
        return [{"id": school, "ok": True, "stale": False, "count": 0,
                 "error": None, "scraped_at": self.stamp} for school in schools]

    def write(self, name, rows):
        path = self.directory / name
        path.write_text(json.dumps({"generated_at": self.stamp, "sources": rows}))
        return path

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(CHECK), str(self.directory), *args],
                              capture_output=True, text=True)

    def test_fresh_sources_can_have_no_listings(self):
        self.write("classes.json", self.classes + [{"id": "other", "ok": False}])
        self.write("shows.json", self.shows)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_publication_with_an_old_success_fails(self):
        self.classes[0]["scraped_at"] = (self.now - timedelta(hours=3)).isoformat()
        self.write("classes.json", self.classes)
        result = self.run_check("--classes-only")
        self.assertEqual(result.returncode, 1)
        self.assertIn("classes.json/ucb_ny", result.stderr)
        self.assertIn(self.classes[0]["scraped_at"], result.stderr)

    def test_retained_failed_and_missing_sources_all_reported(self):
        self.classes[0].update(stale=True, count=5, error="catalog unavailable")
        self.classes[1]["ok"] = False
        self.write("classes.json", self.classes[:2])
        self.write("shows.json", self.shows[:1])
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        for source in ("classes.json/ucb_ny", "catalog unavailable", "classes.json/ucb_la",
                       "classes.json/ucb_online", "shows.json/ucb_la"):
            self.assertIn(source, result.stderr)

    def test_classes_only_does_not_require_shows(self):
        self.write("classes.json", self.classes)
        self.assertEqual(self.run_check("--classes-only").returncode, 0)
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("shows.json", result.stderr)

    def test_two_hour_boundary_and_offset(self):
        boundary = self.now - timedelta(hours=2)
        self.classes[0]["scraped_at"] = boundary.astimezone(timezone(timedelta(hours=-8))).isoformat()
        path = self.write("classes.json", self.classes)
        self.assertEqual(check_feed(path, self.now), [])
        self.assertTrue(check_feed(path, self.now + timedelta(microseconds=1)))

    def test_invalid_future_and_missing_source_timestamps(self):
        for invalid in (None, "invalid", self.now.replace(tzinfo=None).isoformat(),
                        (self.now + timedelta(minutes=1)).isoformat()):
            with self.subTest(invalid=invalid):
                self.classes[0]["scraped_at"] = invalid
                path = self.write("classes.json", self.classes)
                errors = check_feed(path, self.now)
                self.assertEqual(len(errors), 1)
                self.assertIn("classes.json/ucb_ny", errors[0])

    def test_malformed_feed_fails_with_path(self):
        (self.directory / "classes.json").write_text("{")
        result = self.run_check("--classes-only")
        self.assertEqual(result.returncode, 1)
        self.assertIn("classes.json", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

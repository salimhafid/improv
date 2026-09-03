"""Offline tests for the class-alert watcher's pure logic. No network, no
CloudKit — scan/send are exercised only through the functions between them."""
from __future__ import annotations

import unittest

import watcher
from watcher import _categories, _category, compose, diff_and_alert

# Arlo tags on UCB event 42057, "Sketch from Improv" with Kevin McDonald —
# the class that went out as `improv_electives` alone and reached nobody.
MCDONALD_TAGS = ["CTG_Featured_Programs", "CTG_Improv_Electives",
                 "CTG_Sketch_Electives", "FRQ_Workshop", "LOC_NY", "TOD_Afternoon"]


class CategoryTests(unittest.TestCase):
    def test_every_matching_tag_in_priority_order(self):
        self.assertEqual(_categories(MCDONALD_TAGS),
                         ["improv_electives", "sketch_electives", "featured_programs", "workshops"])

    def test_primary_is_first_match(self):
        self.assertEqual(_category(MCDONALD_TAGS), "improv_electives")
        self.assertEqual(_category(["CTG_Improv", "LOC_NY"]), "improv")

    def test_electives_outrank_core_when_both_present(self):
        # The tag list carries Improv_Electives first on purpose.
        self.assertEqual(_categories(["CTG_Improv", "CTG_Improv_Electives"]),
                         ["improv_electives", "improv"])

    def test_no_category_tags_is_other(self):
        self.assertEqual(_categories(["LOC_NY", "TOD_Evening"]), ["other"])
        self.assertEqual(_category([]), "other")


def _ucb(title, categories, cid, when="2026-11-01"):
    return cid, {"title": title, "when": when, "categories": categories}


class DiffAndAlertTests(unittest.TestCase):
    def test_first_sight_baselines_without_alerting(self):
        state = {}
        scanned = {"ucb_ny": dict([_ucb("Improv 101", ["improv"], "1")])}
        self.assertEqual(diff_and_alert(scanned, state, per_category=True), [])
        self.assertEqual(state["ucb_ny"]["ids"], ["1"])

    def test_new_class_carries_every_category(self):
        state = {"ucb_ny": {"ids": ["1"]}}
        scanned = {"ucb_ny": dict([
            _ucb("Improv 101", ["improv"], "1"),
            _ucb("Sketch from Improv", _categories(MCDONALD_TAGS), "42057"),
        ])}
        alerts = diff_and_alert(scanned, state, per_category=True)
        self.assertEqual(len(alerts), 1)
        a = alerts[0]
        self.assertEqual(a["school"], "ucb_ny")
        self.assertEqual(a["categories"],
                         ["improv_electives", "sketch_electives", "featured_programs", "workshops"])
        self.assertEqual(a["category"], "improv_electives", "scalar stays the primary")
        self.assertEqual(a["classIDs"], "42057")
        self.assertEqual(a["pushTitle"], "New class at UCB New York")
        self.assertEqual(a["pushBody"], "Sketch from Improv · starts 2026-11-01")

    def test_bundles_only_classes_sharing_the_same_category_set(self):
        state = {"ucb_ny": {"ids": []}}
        scanned = {"ucb_ny": dict([
            _ucb("Improv 101", ["improv"], "1"),
            _ucb("Improv 201", ["improv"], "2"),
            _ucb("Sketch from Improv", ["improv_electives", "sketch_electives"], "3"),
        ])}
        alerts = diff_and_alert(scanned, state, per_category=True)
        by_ids = {a["classIDs"]: a for a in alerts}
        self.assertEqual(set(by_ids), {"1,2", "3"},
                         "identical sets bundle; a different set is its own record")
        self.assertEqual(by_ids["1,2"]["categories"], ["improv"])
        self.assertEqual(by_ids["1,2"]["pushTitle"], "New Improv classes at UCB New York")
        self.assertEqual(by_ids["3"]["categories"], ["improv_electives", "sketch_electives"])

    def test_non_ucb_schools_bundle_as_all(self):
        state = {"magnet": {"ids": []}}
        scanned = {"magnet": {"a": {"title": "Level One", "when": "2026-10-01"},
                              "b": {"title": "Level Two", "when": "2026-10-02"}}}
        alerts = diff_and_alert(scanned, state, per_category=False)
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["categories"], ["all"])
        self.assertEqual(alerts[0]["category"], "all")
        self.assertEqual(alerts[0]["pushTitle"], "New classes at Magnet Theater")

    def test_state_always_advances_to_current_ids(self):
        state = {"ucb_ny": {"ids": ["old"]}}
        scanned = {"ucb_ny": dict([_ucb("X", ["improv"], "new")])}
        diff_and_alert(scanned, state, per_category=True)
        self.assertEqual(state["ucb_ny"]["ids"], ["new"], "dropped classes leave state")


class OthersStaleTests(unittest.TestCase):
    def _state(self, hours_ago):
        from datetime import datetime, timedelta, timezone
        ts = (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).isoformat()
        return {"ucb_ny": {"ids": [], "updated": ts},
                "magnet": {"ids": [], "updated": ts},
                "second_city": {"ids": [], "updated": ts}}

    def test_never_scanned_is_stale(self):
        self.assertTrue(watcher.others_stale({}, 20))
        self.assertTrue(watcher.others_stale({"ucb_ny": {"ids": [], "updated": "2026-09-03T00:00:00+00:00"}}, 20),
                        "UCB-only state has no non-UCB scan on record")

    def test_recent_scan_is_not_stale(self):
        self.assertFalse(watcher.others_stale(self._state(hours_ago=2), 20))

    def test_old_scan_is_stale(self):
        self.assertTrue(watcher.others_stale(self._state(hours_ago=25), 20))

    def test_ucb_freshness_does_not_count(self):
        state = self._state(hours_ago=30)
        from datetime import datetime, timezone
        state["ucb_ny"]["updated"] = datetime.now(timezone.utc).isoformat()
        self.assertTrue(watcher.others_stale(state, 20), "a fresh UCB scan must not mask stale others")


class ComposeTests(unittest.TestCase):
    def test_primary_drives_the_multi_class_label(self):
        a = compose("ucb_la", ["sketch_electives", "featured_programs"],
                    [{"id": "1", "title": "A", "when": ""}, {"id": "2", "title": "B", "when": ""}])
        self.assertEqual(a["pushTitle"], "New Sketch Electives classes at UCB Los Angeles")
        self.assertEqual(a["pushBody"], "A · B")
        self.assertEqual(a["category"], "sketch_electives")

    def test_body_caps_at_three_titles(self):
        items = [{"id": str(i), "title": f"T{i}", "when": ""} for i in range(5)]
        self.assertEqual(compose("ucb_ny", ["improv"], items)["pushBody"], "T0 · T1 · T2 and 2 more")

    def test_every_category_key_has_a_label(self):
        for _, key in watcher.UCB_CATEGORY_TAGS:
            self.assertIn(key, watcher.CATEGORY_LABEL)


if __name__ == "__main__":
    unittest.main()

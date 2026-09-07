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

    def test_empty_scan_keeps_prior_state_and_alerts_nothing(self):
        # A 200-OK-but-empty scrape (markup change, transient empty body) must
        # not wipe the known ids — the next good scan would alert on all of them.
        state = {"ucb_ny": {"ids": ["1", "2"], "updated": "t0"}, "magnet": {"ids": ["a"], "updated": "t0"}}
        with self.assertLogs("ucb.watcher", level="WARNING"):
            alerts = diff_and_alert({"ucb_ny": {}}, state, per_category=True)
            alerts += diff_and_alert({"magnet": {}}, state, per_category=False)
        self.assertEqual(alerts, [])
        self.assertEqual(state["ucb_ny"], {"ids": ["1", "2"], "updated": "t0"})
        self.assertEqual(state["magnet"], {"ids": ["a"], "updated": "t0"})
        # ...and the following good scan alerts only on what is genuinely new.
        alerts = diff_and_alert({"ucb_ny": dict([_ucb("A", ["improv"], "1"),
                                                 _ucb("B", ["improv"], "2"),
                                                 _ucb("C", ["improv"], "3")])}, state, per_category=True)
        self.assertEqual([a["classIDs"] for a in alerts], ["3"])

    def test_empty_scan_of_a_school_that_was_empty_is_fine(self):
        state = {"ucb_la": {"ids": [], "updated": "t0"}}
        self.assertEqual(diff_and_alert({"ucb_la": {}}, state, per_category=True), [])
        self.assertNotEqual(state["ucb_la"]["updated"], "t0", "a legitimately empty school still advances")

    def test_corrupt_state_entry_is_rebaselined(self):
        state = {"ucb_ny": ["not", "a", "dict"]}
        with self.assertLogs("ucb.watcher", level="WARNING"):
            alerts = diff_and_alert({"ucb_ny": dict([_ucb("X", ["improv"], "1")])}, state, per_category=True)
        self.assertEqual(alerts, [])
        self.assertEqual(state["ucb_ny"]["ids"], ["1"])


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

    def test_single_class_body_is_capped_like_the_list_body(self):
        a = compose("ucb_ny", ["improv"], [{"id": "1", "title": "T" * 300, "when": "2026-11-01"}])
        self.assertEqual(len(a["pushBody"]), 170)


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        import json
        return json.dumps(self._payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _alert(school="ucb_ny", cid="1"):
    return compose(school, ["improv"], [{"id": cid, "title": "Improv 101", "when": ""}])


class SendAlertsRetryTests(unittest.TestCase):
    """CloudKit is never contacted: urlopen and _sign are patched."""

    def setUp(self):
        from unittest.mock import patch
        p1 = patch.object(watcher, "KEY_ID", "key")
        p2 = patch.object(watcher, "PRIVATE_KEY_PEM", "pem")
        p3 = patch.object(watcher, "ENVIRONMENTS", ["development", "production"])
        p4 = patch.object(watcher, "_sign", return_value={})
        for p in (p1, p2, p3, p4):
            p.start()
            self.addCleanup(p.stop)

    def _run(self, alerts, responder):
        from unittest.mock import patch
        calls = []

        def urlopen(req, timeout=None):
            env = req.full_url.split("/")[6]
            calls.append(env)
            return responder(env)
        with patch.object(watcher.urllib.request, "urlopen", side_effect=urlopen):
            return watcher.send_alerts(alerts), calls

    def test_all_accepted_returns_nothing(self):
        unsent, calls = self._run([_alert()], lambda env: _FakeResponse({"records": [{}]}))
        self.assertEqual(unsent, [])
        self.assertEqual(calls, ["development", "production"])

    def test_failed_environment_is_returned_tagged_for_retry(self):
        import io, urllib.error

        def responder(env):
            if env == "production":
                raise urllib.error.HTTPError("u", 401, "auth", {}, io.BytesIO(b"bad key"))
            return _FakeResponse({"records": [{}]})
        unsent, _ = self._run([_alert(), _alert(cid="2")], responder)
        self.assertEqual([a["envs"] for a in unsent], [["production"], ["production"]])
        self.assertEqual([a["classIDs"] for a in unsent], ["1", "2"])

    def test_per_record_server_error_counts_as_unsent(self):
        def urlopen_echo(req, timeout=None):
            # Echo the record names back, failing the last one.
            import json
            ops = json.loads(req.data)["operations"]
            recs = [{"recordName": op["record"]["recordName"]} for op in ops]
            recs[-1]["serverErrorCode"] = "BAD_REQUEST"
            return _FakeResponse({"records": recs})
        from unittest.mock import patch
        with patch.object(watcher.urllib.request, "urlopen", side_effect=urlopen_echo):
            unsent = watcher.send_alerts([_alert(), _alert(cid="2")])
        self.assertEqual([(a["classIDs"], a["envs"]) for a in unsent],
                         [("2", ["development", "production"])])

    def test_retried_alert_only_goes_to_the_environments_it_is_owed(self):
        parked = dict(_alert(), envs=["production"])
        unsent, calls = self._run([parked], lambda env: _FakeResponse({"records": [{}]}))
        self.assertEqual(calls, ["production"])
        self.assertEqual(unsent, [])

    def test_bad_key_does_not_raise_out_of_send(self):
        from unittest.mock import patch
        with patch.object(watcher, "_sign", side_effect=ValueError("not a PEM")):
            unsent, calls = self._run([_alert()], lambda env: _FakeResponse({"records": [{}]}))
        self.assertEqual(calls, [], "signing failed before any request")
        self.assertEqual(unsent[0]["envs"], ["development", "production"])


class MainAtLeastOnceTests(unittest.TestCase):
    """main() with the scans and CloudKit patched: state is written after the
    send, unsent alerts are parked in the state file and retried next run."""

    def setUp(self):
        import os, tempfile
        from unittest.mock import patch
        self.dir = tempfile.mkdtemp()
        p = patch.object(watcher, "STATE_PATH", os.path.join(self.dir, "state.json"))
        p.start(); self.addCleanup(p.stop)

    def _main(self, scanned, send_result, argv=("--ucb",)):
        from unittest.mock import patch
        sent = []

        def send(alerts):
            sent.extend(alerts)
            return send_result(alerts)
        with patch.object(watcher, "scan_ucb", return_value=scanned), \
             patch.object(watcher, "send_alerts", side_effect=send), \
             patch.object(watcher.sys, "argv", ["watcher.py", *argv]):
            rc = watcher.main()
        return rc, sent, watcher.load_state()

    def test_unsent_alerts_are_parked_and_exit_is_nonzero(self):
        watcher.save_state({"ucb_ny": {"ids": ["1"]}, "ucb_la": {"ids": []}, "ucb_online": {"ids": []}})
        scanned = {"ucb_ny": dict([_ucb("A", ["improv"], "1"), _ucb("B", ["improv"], "2")]),
                   "ucb_la": {}, "ucb_online": {}}
        rc, sent, state = self._main(scanned, lambda alerts: [dict(a, envs=["production"]) for a in alerts])
        self.assertEqual(rc, 1)
        self.assertEqual([a["classIDs"] for a in sent], ["2"])
        self.assertEqual(state["ucb_ny"]["ids"], ["1", "2"], "state still advances")
        self.assertEqual([a["classIDs"] for a in state[watcher.PENDING_KEY]], ["2"])
        self.assertEqual(state[watcher.PENDING_KEY][0]["envs"], ["production"])
        self.assertTrue(watcher.others_stale(state, 20), "a parked list is not a school stamp")

        # Next iteration: nothing new, but the parked alert is retried first
        # and, once accepted, the slot is cleared.
        rc, sent, state = self._main(scanned, lambda alerts: [])
        self.assertEqual(rc, 0)
        self.assertEqual([(a["classIDs"], a.get("envs")) for a in sent], [("2", ["production"])])
        self.assertNotIn(watcher.PENDING_KEY, state)

    def test_clean_run_exits_zero_and_parks_nothing(self):
        watcher.save_state({"ucb_ny": {"ids": []}, "ucb_la": {"ids": []}, "ucb_online": {"ids": []}})
        rc, sent, state = self._main({"ucb_ny": dict([_ucb("A", ["improv"], "1")]), "ucb_la": {}, "ucb_online": {}},
                                     lambda alerts: [])
        self.assertEqual(rc, 0)
        self.assertEqual(len(sent), 1)
        self.assertNotIn(watcher.PENDING_KEY, state)

    def test_pending_slot_tolerates_garbage(self):
        self.assertEqual(watcher.pending_alerts({watcher.PENDING_KEY: "junk"}), [])
        self.assertEqual(watcher.pending_alerts({watcher.PENDING_KEY: [{"x": 1}, _alert()]})[0]["school"], "ucb_ny")
        state = {watcher.PENDING_KEY: []}
        watcher.pending_alerts(state)
        self.assertNotIn(watcher.PENDING_KEY, state, "the slot is consumed")


class TestModeTests(unittest.TestCase):
    """--test never touches the production public DB unless --test-prod is passed."""

    def _envs(self, *argv):
        from unittest.mock import patch
        seen = []
        with patch.object(watcher, "ENVIRONMENTS", ["development", "production"]), \
             patch.object(watcher, "test_cloudkit", side_effect=lambda envs: seen.append(envs) or 0), \
             patch.object(watcher.sys, "argv", ["watcher.py", *argv]):
            self.assertEqual(watcher.main(), 0)
        return seen[0]

    def test_test_skips_production_by_default(self):
        self.assertEqual(self._envs("--test"), ["development"])

    def test_test_prod_opts_into_production(self):
        self.assertEqual(self._envs("--test", "--test-prod"), ["development", "production"])

    def test_no_environment_left_to_test_is_a_failure(self):
        # CLOUDKIT_ENVS=production alone + --test filters everything out; that
        # must not read as "auth OK".
        from unittest.mock import patch
        with patch.object(watcher, "KEY_ID", "key"), patch.object(watcher, "PRIVATE_KEY_PEM", "pem"):
            self.assertEqual(watcher.test_cloudkit([]), 1)


if __name__ == "__main__":
    unittest.main()

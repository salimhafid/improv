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
        p5 = patch.object(watcher, "KEY_ID_PROD", "")
        for p in (p1, p2, p3, p4, p5):
            p.start()
            self.addCleanup(p.stop)

    def _run(self, alerts, responder):
        from unittest.mock import patch
        calls = []

        def urlopen(req, timeout=None):
            import json
            env = req.full_url.split("/")[6]
            calls.append(env)
            names = [op["record"]["recordName"] for op in json.loads(req.data)["operations"]]
            return responder(env, names)
        with patch.object(watcher.urllib.request, "urlopen", side_effect=urlopen):
            return watcher.send_alerts(alerts), calls

    def test_all_accepted_returns_nothing(self):
        unsent, calls = self._run([_alert()], self._accepted)
        self.assertEqual(unsent, [])
        self.assertEqual(calls, ["development", "production"])

    def test_failed_environment_is_returned_tagged_for_retry(self):
        import io, urllib.error

        def responder(env, names):
            if env == "production":
                raise urllib.error.HTTPError("u", 401, "auth", {}, io.BytesIO(b"bad key"))
            return self._accepted(env, names)
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
        unsent, calls = self._run([parked], self._accepted)
        self.assertEqual(calls, ["production"])
        self.assertEqual(unsent, [])

    def test_bad_key_does_not_raise_out_of_send(self):
        from unittest.mock import patch
        with patch.object(watcher, "_sign", side_effect=ValueError("not a PEM")):
            unsent, calls = self._run([_alert()], self._accepted)
        self.assertEqual(calls, [], "signing failed before any request")
        self.assertEqual(unsent[0]["envs"], ["development", "production"])

    @staticmethod
    def _accepted(env, names):
        return _FakeResponse({"records": [{"recordName": name} for name in names]})

    def test_incomplete_or_unrelated_acknowledgements_remain_pending(self):
        for response in ({}, [], {"records": []}, {"records": [{}]},
                         {"records": [{"recordName": "some-other-record"}]}):
            with self.subTest(response=response):
                unsent, _ = self._run([_alert()], lambda env, names: _FakeResponse(response))
                self.assertEqual(unsent[0]["envs"], ["development", "production"])

    def test_only_unacknowledged_record_is_retried(self):
        unsent, _ = self._run([_alert(cid="1"), _alert(cid="2")],
                             lambda env, names: self._accepted(env, names[:1]))
        self.assertEqual([(a["classIDs"], a["envs"]) for a in unsent],
                         [("2", ["development", "production"])])

    def test_duplicate_acknowledgement_is_not_accepted(self):
        unsent, _ = self._run([_alert()],
                             lambda env, names: self._accepted(env, names * 2))
        self.assertEqual(unsent[0]["envs"], ["development", "production"])

    def test_missing_credentials_preserve_alerts_without_network_calls(self):
        from unittest.mock import patch
        for setting in ("KEY_ID", "PRIVATE_KEY_PEM"):
            with self.subTest(setting=setting), patch.object(watcher, setting, ""):
                unsent, calls = self._run([_alert()], self._accepted)
                self.assertEqual(calls, [])
                self.assertEqual(unsent[0]["envs"], ["development", "production"])

    def test_production_key_does_not_require_a_development_key(self):
        from unittest.mock import patch
        with patch.object(watcher, "KEY_ID", ""), patch.object(watcher, "KEY_ID_PROD", "production-key"):
            unsent, calls = self._run([_alert()], self._accepted)
        self.assertEqual(calls, ["production"])
        self.assertEqual(unsent[0]["envs"], ["development"])

    def test_missing_environment_configuration_preserves_pending(self):
        from unittest.mock import patch
        alerts = [_alert()]
        with patch.object(watcher, "ENVIRONMENTS", []):
            unsent, calls = self._run(alerts, self._accepted)
        self.assertEqual(calls, [])
        self.assertEqual(unsent, alerts)

    def test_unconfigured_pending_environment_is_preserved_until_reenabled(self):
        from unittest.mock import patch
        parked = dict(_alert(), envs=["production"])
        with patch.object(watcher, "ENVIRONMENTS", ["development"]):
            unsent, calls = self._run([parked], self._accepted)
        self.assertEqual(calls, [], "do not resend an already accepted environment")
        self.assertEqual(unsent, [parked])
        unsent, calls = self._run(unsent, self._accepted)
        self.assertEqual(calls, ["production"])
        self.assertEqual(unsent, [])

    def test_success_in_one_environment_does_not_consume_deferred_environment(self):
        from unittest.mock import patch
        parked = dict(_alert(), envs=["development", "production"])
        with patch.object(watcher, "ENVIRONMENTS", ["development"]):
            unsent, calls = self._run([parked], self._accepted)
        self.assertEqual(calls, ["development"])
        self.assertEqual(unsent, [dict(parked, envs=["production"])])

    def test_duplicate_configured_environments_do_not_duplicate_writes(self):
        from unittest.mock import patch
        with patch.object(watcher, "ENVIRONMENTS", ["development", "production", "production"]):
            unsent, calls = self._run([_alert()], self._accepted)
        self.assertEqual(calls, ["development", "production"])
        self.assertEqual(unsent, [])

    def test_large_backlog_and_fresh_alerts_use_bounded_environment_batches(self):
        parked = [dict(_alert(cid=str(i)), envs=["production"]) for i in range(201)]
        batches = []

        def responder(env, names):
            batches.append((env, len(names)))
            self.assertLessEqual(len(names), 200)
            return self._accepted(env, names)

        unsent, _ = self._run(parked + [_alert(cid="fresh")], responder)
        self.assertEqual(unsent, [])
        self.assertEqual(batches, [("development", 1), ("production", 200), ("production", 2)],
                         "accepted environments are not resent; fresh alerts still reach both")

    def test_failed_batch_does_not_block_later_batches_or_retry_their_successes(self):
        parked = [dict(_alert(cid=str(i)), envs=["production"]) for i in range(201)]

        def responder(env, names):
            if env == "production" and len(names) == 200:
                raise TimeoutError("batch request timed out")
            return self._accepted(env, names)

        unsent, calls = self._run(parked + [_alert(cid="fresh")], responder)
        self.assertEqual(calls, ["development", "production", "production"])
        self.assertEqual(unsent, parked[:200], "only the failed production batch stays pending")
        unsent, calls = self._run(unsent, self._accepted)
        self.assertEqual(calls, ["production"])
        self.assertEqual(unsent, [])

    def test_partial_batch_failure_preserves_only_its_unacknowledged_item(self):
        parked = [dict(_alert(cid=str(i)), envs=["production"]) for i in range(201)]

        def responder(env, names):
            return self._accepted(env, names[:-1] if len(names) == 200 else names)

        unsent, calls = self._run(parked, responder)
        self.assertEqual(calls, ["production", "production"])
        self.assertEqual(unsent, [parked[199]])


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

    def test_missing_credentials_park_new_alert_and_fail_run(self):
        from unittest.mock import patch
        watcher.save_state({"ucb_ny": {"ids": ["1"]}})
        scanned = {"ucb_ny": dict([_ucb("A", ["improv"], "1"), _ucb("B", ["improv"], "2")])}
        send = watcher.send_alerts
        with patch.object(watcher, "PRIVATE_KEY_PEM", ""), \
             patch.object(watcher, "ENVIRONMENTS", ["development", "production"]):
            rc, sent, state = self._main(scanned, send)
        self.assertEqual(rc, 1)
        self.assertEqual(state["ucb_ny"]["ids"], ["1", "2"])
        self.assertEqual(state[watcher.PENDING_KEY][0]["classIDs"], "2")
        self.assertEqual(state[watcher.PENDING_KEY][0]["envs"], ["development", "production"])

    def test_more_than_fifty_failed_alerts_remain_pending_and_all_retry(self):
        parked = [dict(_alert(cid=str(i)), envs=["production"]) for i in range(51)]
        watcher.save_state({"ucb_ny": {"ids": [str(i) for i in range(51)]},
                            watcher.PENDING_KEY: parked})
        scanned = {"ucb_ny": dict(_ucb(f"Class {i}", ["improv"], str(i)) for i in range(52))}
        with self.assertLogs("ucb.watcher", level="WARNING") as logs:
            rc, sent, state = self._main(scanned,
                                         lambda alerts: [dict(a, envs=["production"]) for a in alerts])
        self.assertEqual(rc, 1)
        self.assertEqual([a["classIDs"] for a in sent], [str(i) for i in range(52)])
        self.assertEqual(state[watcher.PENDING_KEY], parked + [dict(sent[-1], envs=["production"])])
        self.assertTrue(any("retaining all 52" in line for line in logs.output))

        rc, sent, state = self._main(scanned, lambda alerts: [])
        self.assertEqual(rc, 0)
        self.assertEqual([a["classIDs"] for a in sent], [str(i) for i in range(52)])
        self.assertNotIn(watcher.PENDING_KEY, state)

    def test_large_deferred_environment_backlog_survives_repeated_runs(self):
        from unittest.mock import patch
        parked = [dict(_alert(cid=str(i)), envs=["production"]) for i in range(51)]
        watcher.save_state({watcher.PENDING_KEY: parked})
        send = watcher.send_alerts
        with patch.object(watcher, "ENVIRONMENTS", ["development"]), \
             patch.object(watcher.urllib.request, "urlopen") as request:
            for _ in range(2):
                with self.assertLogs("ucb.watcher", level="WARNING"):
                    rc, sent, state = self._main({}, send)
                self.assertEqual(rc, 1)
                self.assertEqual(sent, parked)
                self.assertEqual(state[watcher.PENDING_KEY], parked)
            request.assert_not_called()

    def test_dry_run_does_not_send_advance_state_or_consume_pending(self):
        initial = {"ucb_ny": {"ids": ["1"], "updated": "before"},
                   watcher.PENDING_KEY: [dict(_alert(cid="old"), envs=["production"])]}
        watcher.save_state(initial)
        scanned = {"ucb_ny": dict([_ucb("A", ["improv"], "1"), _ucb("B", ["improv"], "2")])}
        rc, sent, state = self._main(scanned, lambda alerts: [], argv=("--ucb", "--dry-run"))
        self.assertEqual(rc, 0)
        self.assertEqual(sent, [])
        self.assertEqual(state, initial)

    def test_first_dry_run_does_not_write_a_baseline(self):
        import os
        scanned = {"ucb_ny": dict([_ucb("A", ["improv"], "1")])}
        rc, sent, state = self._main(scanned, lambda alerts: [], argv=("--ucb", "--dry-run"))
        self.assertEqual(rc, 0)
        self.assertEqual(sent, [])
        self.assertFalse(os.path.exists(watcher.STATE_PATH))

    def test_failed_ucb_scan_still_retries_pending_without_changing_school_state(self):
        from unittest.mock import patch
        school = {"ids": ["1"], "updated": "before"}
        pending = [dict(_alert(cid="2"), envs=["production"])]
        watcher.save_state({"ucb_ny": school, watcher.PENDING_KEY: pending})
        with patch.object(watcher, "scan_ucb", side_effect=RuntimeError("catalog unavailable")), \
             patch.object(watcher, "send_alerts", return_value=[]) as send, \
             patch.object(watcher.sys, "argv", ["watcher.py", "--ucb"]):
            rc = watcher.main()
        self.assertEqual(rc, 1, "the workflow must still report the failed scan")
        send.assert_called_once_with(pending)
        self.assertEqual(watcher.load_state(), {"ucb_ny": school})

    def test_failed_first_ucb_scan_does_not_baseline_school(self):
        from unittest.mock import patch
        with patch.object(watcher, "scan_ucb", side_effect=RuntimeError("catalog unavailable")), \
             patch.object(watcher, "send_alerts", return_value=[]), \
             patch.object(watcher.sys, "argv", ["watcher.py", "--ucb"]):
            self.assertEqual(watcher.main(), 1)
        self.assertEqual(watcher.load_state(), {})


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

    def test_dry_run_refuses_a_writing_test_mode(self):
        from unittest.mock import patch
        with patch.object(watcher, "test_cloudkit") as probe, \
             patch.object(watcher.sys, "argv", ["watcher.py", "--test", "--dry-run"]):
            with self.assertRaises(SystemExit) as error:
                watcher.main()
        self.assertEqual(error.exception.code, 2)
        probe.assert_not_called()


if __name__ == "__main__":
    unittest.main()

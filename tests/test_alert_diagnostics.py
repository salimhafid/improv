"""Offline safety and failure-path checks for the CloudKit diagnostic tools.

Exercise their real request construction and response validation while every
HTTP request and signature is intercepted. No CloudKit credentials or network
access are needed, and no watcher state is read or written.
"""
from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


def _load_tool(name):
    path = Path(__file__).resolve().parents[1] / "tools" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


diagnose = _load_tool("diagnose_class_alerts")
# The probe is also a standalone script, whose sibling import normally resolves
# from tools/. Supply that sibling only during import, without changing the
# application's imports or leaving a tools/ path entry behind in the test run.
with patch.dict(sys.modules, {"diagnose_class_alerts": diagnose}):
    probe = _load_tool("probe_class_alert_subscriptions")


def _response(payload):
    return io.BytesIO(json.dumps(payload).encode())


def _operation(request):
    return json.loads(request.data)["operations"][0]


class DiagnosticHarness(unittest.TestCase):
    def setUp(self):
        for name, value in (
            ("ENVIRONMENTS", ["development", "production"]),
            ("CONTAINER", "iCloud.test.class-alerts"),
            ("KEY_ID", "development-test-key"),
            ("KEY_ID_PROD", "production-test-key"),
            ("PRIVATE_KEY_PEM", "test-key-is-never-parsed"),
        ):
            patcher = patch.object(diagnose.watcher, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(diagnose.watcher, "_sign", return_value={})
        self.sign = patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch("urllib.request.urlopen", side_effect=AssertionError("unexpected request"))
        self.urlopen = patcher.start()
        self.addCleanup(patcher.stop)
        self.output, self.errors = io.StringIO(), io.StringIO()

    def run_main(self, tool):
        with redirect_stdout(self.output), redirect_stderr(self.errors):
            return tool.main()

    @staticmethod
    def acknowledge_subscription(request, **_):
        operation = _operation(request)
        return _response({"subscriptions": [operation["subscription"]]})

    @staticmethod
    def acknowledge_read(request, **_):
        if request.full_url.endswith("/records/query"):
            return _response({"records": []})
        return _response({"subscriptions": []})


class SubscriptionProbeTests(DiagnosticHarness):
    def test_probe_only_modifies_its_own_impossible_school_subscriptions(self):
        self.urlopen.side_effect = self.acknowledge_subscription
        self.assertEqual(self.run_main(probe), 0)
        requests = [call.args[0] for call in self.urlopen.call_args_list]
        self.assertEqual(len(requests), 4)
        created_ids = set()
        for env, (create, delete) in zip(("development", "production"),
                                       (requests[:2], requests[2:])):
            for request in (create, delete):
                self.assertEqual(request.get_method(), "POST")
                self.assertTrue(request.full_url.endswith(f"/{env}/public/subscriptions/modify"))
            created, deleted = _operation(create), _operation(delete)
            self.assertEqual((created["operationType"], deleted["operationType"]),
                             ("create", "delete"))
            subscription = created["subscription"]
            sid = subscription["subscriptionID"]
            self.assertTrue(sid.startswith("improv-diagnostic/"))
            self.assertNotIn(sid, created_ids)
            created_ids.add(sid)
            self.assertEqual(deleted["subscription"], {"subscriptionID": sid})
            filters = subscription["query"]["filterBy"]
            school_filter = next(f for f in filters if f["fieldName"] == "school")
            self.assertEqual(school_filter["comparator"], "EQUALS")
            self.assertEqual(school_filter["fieldValue"]["value"], "__improv_diagnostic__")
            self.assertEqual(subscription["query"]["recordType"], "ClassAlert")
            self.assertTrue(any(f["fieldName"] == "categories" and
                                f["comparator"] == "LIST_CONTAINS" for f in filters))

    def test_production_item_error_is_reported_after_development_cleanup(self):
        def answer(request, **kwargs):
            if "/production/" in request.full_url:
                operation = _operation(request)
                sid = operation["subscription"]["subscriptionID"]
                if operation["operationType"] == "delete":
                    return _response({"subscriptions": [{"subscriptionID": sid,
                                                         "serverErrorCode": "UNKNOWN_ITEM"}]})
                return _response({"subscriptions": [{"subscriptionID": sid,
                    "serverErrorCode": "INVALID_ARGUMENT", "reason": "query type is not deployed"}]})
            return self.acknowledge_subscription(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(probe), 1)
        requests = [call.args[0] for call in self.urlopen.call_args_list]
        self.assertEqual([_operation(r)["operationType"] for r in requests],
                         ["create", "delete", "create", "delete"])
        self.assertIn("production: subscription creation FAILED: INVALID_ARGUMENT", self.errors.getvalue())
        self.assertIn("query type is not deployed", self.errors.getvalue())
        self.assertIn("development: temporary subscription removed", self.output.getvalue())

    def test_cleanup_failure_is_nonzero_and_identifies_the_owned_subscription(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        created_ids = []

        def answer(request, **kwargs):
            operation = _operation(request)
            sid = operation["subscription"]["subscriptionID"]
            if operation["operationType"] == "create":
                created_ids.append(sid)
                return self.acknowledge_subscription(request, **kwargs)
            raise urllib.error.URLError("connection lost during cleanup")

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(probe), 1)
        self.assertEqual(self.urlopen.call_count, 2)
        self.assertIn(f"cleanup FAILED for {created_ids[0]}", self.errors.getvalue())

    def test_missing_or_ambiguous_create_acknowledgment_cannot_report_success(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        for kind in ("missing", "wrong_id", "duplicate"):
            with self.subTest(kind=kind):
                self.urlopen.reset_mock()

                def answer(request, **_):
                    operation = _operation(request)
                    subscription = operation["subscription"]
                    if operation["operationType"] == "delete":
                        return _response({"subscriptions": [subscription]})
                    if kind == "missing":
                        return _response({})
                    if kind == "wrong_id":
                        return _response({"subscriptions": [{"subscriptionID": "alert/v2/ucb_ny/improv"}]})
                    return _response({"subscriptions": [subscription, subscription]})

                self.urlopen.side_effect = answer
                self.assertEqual(self.run_main(probe), 1)
                # The create may have committed despite its malformed reply.
                # Delete our generated ID, never an unrelated returned ID.
                self.assertEqual(self.urlopen.call_count, 2)
                create, delete = [_operation(c.args[0]) for c in self.urlopen.call_args_list]
                owned_id = create["subscription"]["subscriptionID"]
                self.assertEqual(delete, {"operationType": "delete",
                                          "subscription": {"subscriptionID": owned_id}})
                self.assertNotEqual(owned_id, "alert/v2/ucb_ny/improv")

    def test_lost_create_reply_still_cleans_up_committed_subscription(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        stored_ids = set()
        generated_ids = []

        def answer(request, **kwargs):
            operation = _operation(request)
            sid = operation["subscription"]["subscriptionID"]
            if operation["operationType"] == "create":
                stored_ids.add(sid)
                generated_ids.append(sid)
                raise TimeoutError("reply lost after create committed")
            stored_ids.remove(sid)
            return self.acknowledge_subscription(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(probe), 1)
        self.assertEqual(self.urlopen.call_count, 2)
        self.assertEqual(stored_ids, set())
        self.assertIn(generated_ids[0], self.errors.getvalue())

    def test_delete_already_absent_is_a_noop_for_shared_helper_callers(self):
        sid = "improv-diagnostic/owned-test-id"
        for error_kind in ("UNKNOWN_ITEM", "NOT_FOUND", "HTTP404"):
            with self.subTest(error_kind=error_kind):
                self.urlopen.reset_mock()

                def answer(request, **_):
                    if error_kind == "HTTP404":
                        raise urllib.error.HTTPError(request.full_url, 404, "Not found", {}, io.BytesIO())
                    return _response({"subscriptions": [{"subscriptionID": sid,
                                                         "serverErrorCode": error_kind}]})

                self.urlopen.side_effect = answer
                self.assertEqual(probe.modify("production", "delete", {"subscriptionID": sid}), {})
                self.assertEqual(self.urlopen.call_count, 1)

    def test_delete_permission_failure_is_not_mistaken_for_already_absent(self):
        sid = "improv-diagnostic/owned-test-id"
        self.urlopen.side_effect = lambda *_args, **_kwargs: _response({"subscriptions": [{
            "subscriptionID": sid, "serverErrorCode": "ACCESS_DENIED", "reason": "not permitted"}]})
        with self.assertRaises(probe.CloudKitSubscriptionError) as raised:
            probe.modify("production", "delete", {"subscriptionID": sid})
        self.assertEqual(raised.exception.code, "ACCESS_DENIED")
        self.assertEqual(raised.exception.subscription_id, sid)

    def test_missing_credentials_or_environments_make_no_requests(self):
        for field, value in (("ENVIRONMENTS", []), ("PRIVATE_KEY_PEM", "")):
            with self.subTest(field=field), patch.object(diagnose.watcher, field, value):
                self.assertEqual(self.run_main(probe), 1)
                self.urlopen.assert_not_called()
                self.sign.assert_not_called()


class ReadOnlyDiagnosticTests(DiagnosticHarness):
    def test_success_only_queries_records_and_lists_subscriptions(self):
        self.urlopen.side_effect = self.acknowledge_read
        self.assertEqual(self.run_main(diagnose), 0)
        requests = [call.args[0] for call in self.urlopen.call_args_list]
        self.assertEqual(len(requests), 6)
        for env, group in zip(("development", "production"), (requests[:3], requests[3:])):
            self.assertEqual([(r.get_method(), r.full_url.rsplit("/public/", 1)[1]) for r in group],
                             [("POST", "records/query"), ("POST", "records/query"),
                              ("GET", "subscriptions/list")])
            self.assertTrue(all(f"/{env}/public/" in r.full_url for r in group))
            self.assertIsNone(group[2].data)
            for request in group[:2]:
                self.assertNotIn("operations", json.loads(request.data))
        self.assertIn("do not verify", self.output.getvalue())

    def test_missing_private_key_or_environments_make_no_requests(self):
        for field, value in (("ENVIRONMENTS", []), ("PRIVATE_KEY_PEM", "")):
            with self.subTest(field=field), patch.object(diagnose.watcher, field, value):
                self.assertEqual(self.run_main(diagnose), 1)
                self.urlopen.assert_not_called()
                self.sign.assert_not_called()

    def test_missing_environment_key_skips_that_environment_but_checks_the_other(self):
        diagnose.watcher.KEY_ID = ""
        self.urlopen.side_effect = self.acknowledge_read
        self.assertEqual(self.run_main(diagnose), 1)
        self.assertEqual(self.urlopen.call_count, 3)
        self.assertTrue(all("/production/" in c.args[0].full_url for c in self.urlopen.call_args_list))
        self.assertIn("development: CloudKit key ID is missing", self.errors.getvalue())

    def test_missing_malformed_and_per_record_query_errors_fail(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        for payload in ({}, [], {"records": None},
                        {"records": [{"serverErrorCode": "ACCESS_DENIED"}]}):
            with self.subTest(payload=payload):
                self.urlopen.reset_mock()

                def answer(request, **kwargs):
                    if request.full_url.endswith("/records/query"):
                        return _response(payload)
                    return self.acknowledge_read(request, **kwargs)

                self.urlopen.side_effect = answer
                self.assertEqual(self.run_main(diagnose), 1)
                self.assertEqual(self.urlopen.call_count, 3)

    def test_query_auth_error_is_nonzero_and_does_not_block_other_environment(self):
        def answer(request, **kwargs):
            if "/development/" in request.full_url and request.full_url.endswith("/records/query"):
                raise urllib.error.HTTPError(request.full_url, 401, "Unauthorized", {},
                                             io.BytesIO(b'{"reason":"key rejected"}'))
            return self.acknowledge_read(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(diagnose), 1)
        self.assertEqual(self.urlopen.call_count, 6)
        self.assertIn("HTTP 401", self.errors.getvalue())
        self.assertIn("production / UCB category: OK", self.output.getvalue())


if __name__ == "__main__":
    unittest.main()

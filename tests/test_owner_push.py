"""Offline isolation and cleanup tests for the explicitly requested owner push.

Exercise real HTTP request construction while intercepting every request,
signature, and sleep. No CloudKit records or subscriptions are created.
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
from unittest.mock import call, patch


def _load_tool(name):
    path = Path(__file__).resolve().parents[1] / "tools" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


diagnose = _load_tool("diagnose_class_alerts")
with patch.dict(sys.modules, {"diagnose_class_alerts": diagnose}):
    probe = _load_tool("probe_class_alert_subscriptions")
    with patch.dict(sys.modules, {"probe_class_alert_subscriptions": probe}):
        owner = _load_tool("test_class_alert_push")


def _response(payload):
    return io.BytesIO(json.dumps(payload).encode())


def _operation(request):
    return json.loads(request.data)["operations"][0]


class OwnerPushTests(unittest.TestCase):
    def setUp(self):
        for field, value in (("CONTAINER", "iCloud.test.owner-push"),
                             ("KEY_ID", "development-test-key"),
                             ("KEY_ID_PROD", "production-test-key"),
                             ("PRIVATE_KEY_PEM", "not-a-real-key"),
                             ("ENVIRONMENTS", ["development", "production"])):
            patcher = patch.object(owner.watcher, field, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        for target, name, kwargs in (
            (owner.watcher, "_sign", {"return_value": {}}),
            (owner.time, "sleep", {}),
            (owner.urllib.request, "urlopen", {"side_effect": AssertionError("unexpected HTTP request")}),
        ):
            patcher = patch.object(target, name, **kwargs)
            setattr(self, name, patcher.start())
            self.addCleanup(patcher.stop)
        self.output, self.errors = io.StringIO(), io.StringIO()

    def run_main(self, argv=None):
        with redirect_stdout(self.output), redirect_stderr(self.errors):
            return owner.main(["--send"] if argv is None else argv)

    @staticmethod
    def acknowledge(request, **_):
        operation = _operation(request)
        if "subscription" in operation:
            return _response({"subscriptions": [operation["subscription"]]})
        return _response({"records": [operation["record"]]})

    def operations(self):
        return [_operation(c.args[0]) for c in self.urlopen.call_args_list]

    def test_only_production_and_a_matching_unique_school_receive_the_test(self):
        self.urlopen.side_effect = self.acknowledge
        self.assertEqual(self.run_main(), 0)
        requests = [c.args[0] for c in self.urlopen.call_args_list]
        self.assertEqual(len(requests), 4)
        self.assertTrue(all(r.get_method() == "POST" for r in requests))
        self.assertTrue(all("/production/public/" in r.full_url for r in requests))
        self.assertTrue(all(c.args[2] == "production" for c in self._sign.call_args_list))
        sub_create, record_create, record_delete, sub_delete = self.operations()
        self.assertEqual([op["operationType"] for op in self.operations()],
                         ["create", "create", "delete", "delete"])
        subscription = sub_create["subscription"]
        record = record_create["record"]
        filters = subscription["query"]["filterBy"]
        school_filter = next(f for f in filters if f["fieldName"] == "school")
        school = record["fields"]["school"]["value"]
        self.assertRegex(school, r"^__improv_diagnostic_[0-9a-f]{32}__$")
        self.assertEqual(school_filter["comparator"], "EQUALS")
        self.assertEqual(school_filter["fieldValue"]["value"], school)
        category_filter = next(f for f in filters if f["fieldName"] == "categories")
        self.assertEqual(category_filter["comparator"], "LIST_CONTAINS")
        self.assertIn(category_filter["fieldValue"]["value"], record["fields"]["categories"]["value"])
        self.assertEqual(subscription["query"]["recordType"], "ClassAlert")
        self.assertEqual(record["recordType"], "ClassAlert")
        self.assertEqual(subscription["firesOn"], ["create"])
        info = subscription["notificationInfo"]
        self.assertEqual(info["titleLocalizationKey"], "CA_TITLE")
        self.assertEqual(info["titleLocalizationArgs"], ["pushTitle"])
        self.assertEqual(info["alertLocalizationKey"], "CA_BODY")
        self.assertEqual(info["alertLocalizationArgs"], ["pushBody"])
        self.assertEqual(record_delete["record"],
                         {"recordType": "ClassAlert", "recordName": record["recordName"]})
        self.assertEqual(sub_delete["subscription"], {"subscriptionID": subscription["subscriptionID"]})
        self.assertTrue(subscription["subscriptionID"].startswith("improv-diagnostic/"))
        self.assertEqual(self.sleep.call_args_list, [call(10), call(45)])
        self.assertIn("not confirmed push receipt", self.output.getvalue())

    def test_repeated_tests_use_different_schools_and_cleanup_ids(self):
        self.urlopen.side_effect = self.acknowledge
        self.assertEqual(self.run_main(), 0)
        first = self.operations()[1]["record"]
        self.urlopen.reset_mock()
        self.assertEqual(self.run_main(), 0)
        second = self.operations()[1]["record"]
        self.assertNotEqual(first["fields"]["school"], second["fields"]["school"])
        self.assertNotEqual(first["recordName"], second["recordName"])

    def test_explicit_send_argument_is_required_before_any_request(self):
        with self.assertRaises(SystemExit) as error:
            self.run_main([])
        self.assertEqual(error.exception.code, 2)
        self.urlopen.assert_not_called()
        self._sign.assert_not_called()
        self.sleep.assert_not_called()

    def test_missing_credentials_make_no_requests(self):
        with patch.object(owner.watcher, "PRIVATE_KEY_PEM", ""):
            self.assertEqual(self.run_main(), 1)
        with patch.object(owner.watcher, "KEY_ID", ""), patch.object(owner.watcher, "KEY_ID_PROD", ""):
            self.assertEqual(self.run_main(), 1)
        self.urlopen.assert_not_called()
        self._sign.assert_not_called()
        self.sleep.assert_not_called()

    def test_subscription_failure_never_creates_a_record(self):
        def answer(request, **kwargs):
            operation = _operation(request)
            if operation["operationType"] == "create":
                return _response({"subscriptions": [{
                    "subscriptionID": operation["subscription"]["subscriptionID"],
                    "serverErrorCode": "BAD_REQUEST", "reason": "query type unavailable"}]})
            return self.acknowledge(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(), 1)
        operations = self.operations()
        self.assertEqual(len(operations), 2)
        self.assertTrue(all("subscription" in op for op in operations))
        self.assertEqual(operations[1]["subscription"],
                         {"subscriptionID": operations[0]["subscription"]["subscriptionID"]})
        self.sleep.assert_not_called()

    def test_ambiguous_subscription_write_still_cleans_only_its_generated_id(self):
        def answer(request, **kwargs):
            if _operation(request)["operationType"] == "create":
                raise urllib.error.URLError("response lost after subscription write")
            return self.acknowledge(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(), 1)
        created, deleted = self.operations()
        self.assertEqual(deleted["operationType"], "delete")
        self.assertEqual(deleted["subscription"],
                         {"subscriptionID": created["subscription"]["subscriptionID"]})
        self.assertTrue(all("record" not in op for op in self.operations()))

    def test_ambiguous_record_writes_cleanup_both_generated_objects(self):
        for failure in ("lost_response", "missing_ack", "wrong_ack", "duplicate_ack"):
            with self.subTest(failure=failure):
                self.urlopen.reset_mock()

                def answer(request, **kwargs):
                    op = _operation(request)
                    if "record" in op and op["operationType"] == "create":
                        if failure == "lost_response":
                            raise urllib.error.URLError("response lost after record write")
                        if failure == "missing_ack":
                            return _response({})
                        if failure == "wrong_ack":
                            return _response({"records": [{"recordName": "unrelated-real-record"}]})
                        return _response({"records": [op["record"], op["record"]]})
                    return self.acknowledge(request, **kwargs)

                self.urlopen.side_effect = answer
                self.assertEqual(self.run_main(), 1)
                sub_create, rec_create, rec_delete, sub_delete = self.operations()
                self.assertEqual(rec_delete["record"]["recordName"], rec_create["record"]["recordName"])
                self.assertEqual(sub_delete["subscription"]["subscriptionID"],
                                 sub_create["subscription"]["subscriptionID"])

    def test_record_cleanup_not_found_is_already_clean(self):
        def answer(request, **kwargs):
            op = _operation(request)
            if "record" in op and op["operationType"] == "delete":
                return _response({"records": [{"recordName": op["record"]["recordName"],
                                               "serverErrorCode": "NOT_FOUND"}]})
            return self.acknowledge(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(), 0)
        self.assertNotIn("Cleanup FAILED", self.errors.getvalue())

    def test_record_cleanup_failure_still_attempts_subscription_cleanup(self):
        def answer(request, **kwargs):
            op = _operation(request)
            if "record" in op and op["operationType"] == "delete":
                raise urllib.error.URLError("record cleanup unavailable")
            return self.acknowledge(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(), 1)
        self.assertEqual(len(self.operations()), 4)
        self.assertEqual(self.operations()[-1]["operationType"], "delete")
        self.assertIn("subscription", self.operations()[-1])
        self.assertIn(self.operations()[1]["record"]["recordName"], self.errors.getvalue())


if __name__ == "__main__":
    unittest.main()

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


def _is_query(request):
    return request.full_url.endswith("/records/query")


def _modify_requests(urlopen):
    """The probe's subscription create/delete requests, in order, without its
    read-only LIST_CONTAINS_ANY record query."""
    return [c.args[0] for c in urlopen.call_args_list if not _is_query(c.args[0])]


def _alert_record(*categories):
    return {"recordName": "class-alert-test", "recordType": "ClassAlert",
            "fields": {"categories": {"value": list(categories), "type": "STRING_LIST"}}}


# Every shipped subscription shape's category filter, in QUERY_SHAPES order
# (school-only adds none). ucb-v3 sends the picks as one STRING_LIST value.
_CATEGORY_FILTERS = [
    [],
    [{"fieldName": "category", "comparator": "EQUALS",
      "fieldValue": {"value": "improv", "type": "STRING"}}],
    [{"fieldName": "categories", "comparator": "LIST_CONTAINS",
      "fieldValue": {"value": "improv", "type": "STRING"}}],
    [{"fieldName": "categories", "comparator": "LIST_CONTAINS_ANY",
      "fieldValue": {"value": ["improv", "standup"], "type": "STRING_LIST"}}],
]
_SHAPES = ("school-only", "ucb-legacy", "ucb-v2", "ucb-v3")


def _native_notification_info():
    # Independent fixture using normalized native REST response names, not an
    # echo of the request: unknown request keys can be silently discarded.
    return {"titleLocalizedKey": "CA_TITLE", "titleLocalizedArguments": ["pushTitle"],
            "alertLocalizationKey": "CA_BODY", "alertLocalizationArgs": ["pushBody"],
            "soundName": "default", "subtitleLocalizedKey": "",
            "subtitleLocalizedArguments": [], "additionalFields": []}


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

    def run_main(self, tool, argv=()):
        with patch.object(sys, "argv", [tool.__name__, *argv]), \
                redirect_stdout(self.output), redirect_stderr(self.errors):
            return tool.main()

    @staticmethod
    def acknowledge_subscription(request, **_):
        if _is_query(request):
            # The probe's read-only contains-any check; an empty result is a
            # valid answer. Tests of that check answer it themselves.
            return _response({"records": []})
        operation = _operation(request)
        subscription = {"subscriptionID": operation["subscription"]["subscriptionID"]}
        if operation["operationType"] == "create":
            subscription["notificationInfo"] = _native_notification_info()
        return _response({"subscriptions": [subscription]})

    @staticmethod
    def acknowledge_read(request, **_):
        if request.full_url.endswith("/records/query"):
            return _response({"records": []})
        return _response({"subscriptions": []})


class SubscriptionProbeTests(DiagnosticHarness):
    def test_stripped_or_changed_notification_fields_fail_and_cleanup_every_shape(self):
        diagnose.watcher.ENVIRONMENTS = ["development"]
        cases = [(key, value) for key in ("titleLocalizedKey", "titleLocalizedArguments",
                                         "alertLocalizationKey", "alertLocalizationArgs", "soundName")
                 for value in (None, "wrong-value")]
        cases.extend([(None, None), (None, [])])
        for key, value in cases:
            with self.subTest(key=key, value=value):
                self.urlopen.reset_mock()
                self.output = io.StringIO()

                def answer(request, **kwargs):
                    if _is_query(request) or _operation(request)["operationType"] != "create":
                        return self.acknowledge_subscription(request, **kwargs)
                    operation = _operation(request)
                    info = _native_notification_info()
                    if key is None:
                        info = value
                    elif value is None:
                        del info[key]
                    else:
                        info[key] = value
                    return _response({"subscriptions": [{
                        "subscriptionID": operation["subscription"]["subscriptionID"],
                        "notificationInfo": info}]})

                self.urlopen.side_effect = answer
                self.assertEqual(self.run_main(probe), 1)
                operations = [_operation(r) for r in _modify_requests(self.urlopen)]
                self.assertEqual(len(operations), 8)
                self.assertEqual(self.urlopen.call_count, 9)   # + the contains-any query
                for create, delete in zip(operations[::2], operations[1::2]):
                    self.assertEqual(delete, {"operationType": "delete", "subscription": {
                        "subscriptionID": create["subscription"]["subscriptionID"]}})
                self.assertNotIn("subscription type accepted", self.output.getvalue())
                self.assertIn("notificationInfo", self.errors.getvalue())

    def test_matrix_exercises_every_shape_order_and_scope_without_record_writes(self):
        self.urlopen.side_effect = self.acknowledge_subscription
        self.assertEqual(self.run_main(probe, ["--matrix"]), 0)
        requests = [call.args[0] for call in self.urlopen.call_args_list]
        # 4 shapes x 2 orders x 2 scopes x (create + delete) x 2 environments;
        # the matrix skips the record query.
        self.assertEqual(len(requests), 64)
        self.assertFalse(any(_is_query(r) for r in requests))
        created_ids = set()
        variants_by_env = {env: [] for env in ("development", "production")}
        for create, delete in zip(requests[::2], requests[1::2]):
            env = "development" if "/development/" in create.full_url else "production"
            self.assertTrue(create.full_url.endswith(f"/{env}/public/subscriptions/modify"))
            self.assertEqual(delete.full_url, create.full_url)
            created = _operation(create)
            self.assertEqual(created["operationType"], "create")
            subscription = created["subscription"]
            sid = subscription["subscriptionID"]
            self.assertRegex(sid, r"^improv-diagnostic/[0-9a-f]{32}$")
            self.assertNotIn(sid, created_ids)
            created_ids.add(sid)
            self.assertEqual(_operation(delete), {"operationType": "delete",
                                                 "subscription": {"subscriptionID": sid}})
            filters = subscription["query"]["filterBy"]
            school = next(f for f in filters if f["fieldName"] == "school")
            self.assertEqual(school, {"fieldName": "school", "comparator": "EQUALS",
                                     "fieldValue": {"value": "__improv_diagnostic__",
                                                    "type": "STRING"}})
            self.assertEqual(subscription["query"]["recordType"], "ClassAlert")
            self.assertEqual(subscription["firesOn"], ["create"])
            self.assertFalse(subscription["firesOnce"])
            self.assertEqual(subscription["notificationInfo"], {
                "titleLocalizedKey": "CA_TITLE", "titleLocalizedArguments": ["pushTitle"],
                "alertLocalizationKey": "CA_BODY", "alertLocalizationArgs": ["pushBody"],
                "soundName": "default"})
            if subscription["zoneWide"]:
                self.assertNotIn("zoneID", subscription)
            else:
                self.assertEqual(subscription["zoneID"], {"zoneName": "_defaultZone"})
            for f in filters:
                if f["comparator"] == "LIST_CONTAINS_ANY":
                    self.assertEqual(f["fieldValue"], {"value": ["improv", "standup"],
                                                       "type": "STRING_LIST"})
            variants_by_env[env].append((tuple((f["fieldName"], f["comparator"])
                                               for f in filters), subscription["zoneWide"]))
        expected = []
        for field, comparator in ((None, None), ("category", "EQUALS"),
                                  ("categories", "LIST_CONTAINS"),
                                  ("categories", "LIST_CONTAINS_ANY")):
            order = [("school", "EQUALS")]
            if field:
                order.append((field, comparator))
            for filters in (order, list(reversed(order))):
                for zone_wide in (True, False):
                    expected.append((tuple(filters), zone_wide))
        for env, actual in variants_by_env.items():
            self.assertEqual(actual, expected)
            for shape in ("ucb-v2", "ucb-v3"):
                self.assertIn(f"{env} / {shape} / reversed / default-zone: subscription type accepted",
                              self.output.getvalue())

    def test_matrix_rejection_still_cleans_owned_id_and_continues_other_variants(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]

        def answer(request, **kwargs):
            operation = _operation(request)
            subscription = operation["subscription"]
            if operation["operationType"] == "create" and not subscription["zoneWide"]:
                # A server-side create might commit before returning an error.
                raise urllib.error.HTTPError(request.full_url, 400, "Bad request", {},
                                             io.BytesIO(b'{"reason":"scope type not deployed"}'))
            return self.acknowledge_subscription(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(probe, ["--matrix"]), 1)
        operations = [_operation(c.args[0]) for c in self.urlopen.call_args_list]
        self.assertEqual(len(operations), 32)
        for create, delete in zip(operations[::2], operations[1::2]):
            self.assertEqual(delete, {"operationType": "delete", "subscription": {
                "subscriptionID": create["subscription"]["subscriptionID"]}})
        self.assertIn("production / ucb-v2 / reversed / all-zones: subscription type accepted",
                      self.output.getvalue())
        self.assertIn("production / ucb-v2 / reversed / default-zone: subscription creation HTTP 400",
                      self.errors.getvalue())
        self.assertIn("scope type not deployed", self.errors.getvalue())

    def test_probe_only_modifies_its_own_impossible_school_subscriptions(self):
        self.urlopen.side_effect = self.acknowledge_subscription
        self.assertEqual(self.run_main(probe), 0)
        requests = [call.args[0] for call in self.urlopen.call_args_list]
        # Per environment: create + delete for each of the 4 shapes, then one
        # read-only contains-any record query.
        self.assertEqual(len(requests), 18)
        created_ids = set()
        for env, group in zip(("development", "production"), (requests[:9], requests[9:])):
            query = group[8]
            self.assertEqual(query.get_method(), "POST")
            self.assertTrue(query.full_url.endswith(f"/{env}/public/records/query"))
            body = json.loads(query.data)
            self.assertNotIn("operations", body)
            self.assertEqual(body["query"], {"recordType": "ClassAlert", "filterBy": [
                {"fieldName": "school", "comparator": "EQUALS",
                 "fieldValue": {"value": "ucb_ny", "type": "STRING"}},
                {"fieldName": "categories", "comparator": "LIST_CONTAINS_ANY",
                 "fieldValue": {"value": ["standup", "writing_programs"], "type": "STRING_LIST"}}]})
            for index, extra_filters in enumerate(_CATEGORY_FILTERS):
                create, delete = group[index * 2:index * 2 + 2]
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
                self.assertEqual(subscription["query"], {"recordType": "ClassAlert", "filterBy": [
                    {"fieldName": "school", "comparator": "EQUALS",
                     "fieldValue": {"value": "__improv_diagnostic__", "type": "STRING"}},
                    *extra_filters]})
                self.assertEqual(subscription["firesOn"], ["create"])
                self.assertFalse(subscription["firesOnce"])
                self.assertTrue(subscription["zoneWide"])
                self.assertEqual(subscription["notificationInfo"], {
                    "titleLocalizedKey": "CA_TITLE", "titleLocalizedArguments": ["pushTitle"],
                    "alertLocalizationKey": "CA_BODY", "alertLocalizationArgs": ["pushBody"],
                    "soundName": "default"})
            for shape in _SHAPES:
                self.assertIn(f"{env} / {shape}: subscription type accepted", self.output.getvalue())
            self.assertIn(f"{env} / contains-any query: 0 record(s)", self.output.getvalue())
        self.assertEqual(self.output.getvalue().count("title/body payload verified"), 8)

    def test_production_item_error_is_reported_after_development_cleanup(self):
        def answer(request, **kwargs):
            if "/production/" in request.full_url and not _is_query(request):
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
        self.assertEqual([_operation(r)["operationType"] for r in _modify_requests(self.urlopen)],
                         ["create", "delete"] * 8)
        self.assertIn("production / ucb-legacy: subscription creation FAILED: INVALID_ARGUMENT",
                      self.errors.getvalue())
        self.assertIn("query type is not deployed", self.errors.getvalue())
        self.assertIn("development / ucb-v2: temporary subscription removed", self.output.getvalue())

    def test_one_rejected_query_shape_does_not_block_other_shapes(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]

        def answer(request, **kwargs):
            if _is_query(request):
                return self.acknowledge_subscription(request, **kwargs)
            operation = _operation(request)
            subscription = operation["subscription"]
            if operation["operationType"] == "create" and any(
                    f["fieldName"] == "category" for f in subscription["query"]["filterBy"]):
                raise urllib.error.HTTPError(request.full_url, 400, "Bad request", {},
                                             io.BytesIO(b'{"reason":"legacy type not deployed"}'))
            return self.acknowledge_subscription(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(probe), 1)
        self.assertEqual(self.urlopen.call_count, 9)
        self.assertIn("production / ucb-legacy: subscription creation HTTP 400", self.errors.getvalue())
        for shape in ("school-only", "ucb-v2", "ucb-v3"):
            self.assertIn(f"production / {shape}: subscription type accepted", self.output.getvalue())

    def test_cleanup_failure_is_nonzero_and_identifies_the_owned_subscription(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        created_ids = []

        def answer(request, **kwargs):
            if _is_query(request):
                return self.acknowledge_subscription(request, **kwargs)
            operation = _operation(request)
            sid = operation["subscription"]["subscriptionID"]
            if operation["operationType"] == "create":
                created_ids.append(sid)
                return self.acknowledge_subscription(request, **kwargs)
            raise urllib.error.URLError("connection lost during cleanup")

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(probe), 1)
        self.assertEqual(self.urlopen.call_count, 9)
        self.assertEqual(len(created_ids), 4)
        for sid in created_ids:
            self.assertIn(f"cleanup FAILED for {sid}", self.errors.getvalue())

    def test_missing_or_ambiguous_create_acknowledgment_cannot_report_success(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        for kind in ("missing", "wrong_id", "duplicate"):
            with self.subTest(kind=kind):
                self.urlopen.reset_mock()

                def answer(request, **kwargs):
                    if _is_query(request):
                        return self.acknowledge_subscription(request, **kwargs)
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
                self.assertEqual(self.urlopen.call_count, 9)
                operations = [_operation(r) for r in _modify_requests(self.urlopen)]
                self.assertEqual(len(operations), 8)
                for create, delete in zip(operations[::2], operations[1::2]):
                    owned_id = create["subscription"]["subscriptionID"]
                    self.assertEqual(delete, {"operationType": "delete",
                                              "subscription": {"subscriptionID": owned_id}})
                    self.assertNotEqual(owned_id, "alert/v2/ucb_ny/improv")

    def test_lost_create_reply_still_cleans_up_committed_subscription(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        stored_ids = set()
        generated_ids = []

        def answer(request, **kwargs):
            if _is_query(request):
                return self.acknowledge_subscription(request, **kwargs)
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
        self.assertEqual(self.urlopen.call_count, 9)
        self.assertEqual(len(generated_ids), 4)
        self.assertEqual(stored_ids, set())
        for sid in generated_ids:
            self.assertIn(sid, self.errors.getvalue())

    def assert_every_create_was_cleaned_up(self):
        operations = [_operation(r) for r in _modify_requests(self.urlopen)]
        self.assertEqual(len(operations), 8 * len(diagnose.watcher.ENVIRONMENTS))
        for create, delete in zip(operations[::2], operations[1::2]):
            self.assertEqual(create["operationType"], "create")
            self.assertEqual(delete, {"operationType": "delete", "subscription": {
                "subscriptionID": create["subscription"]["subscriptionID"]}})

    def test_contains_any_query_must_only_return_records_sharing_a_queried_category(self):
        # ucb-v3 is one subscription per school matching ANY picked category;
        # a server that matched records outside the picks would push classes
        # the user never chose.
        diagnose.watcher.ENVIRONMENTS = ["production"]
        cases = [
            ("all match", [_alert_record("standup"),
                           _alert_record("writing_programs", "featured_programs"),
                           _alert_record("standup", "writing_programs")], 0),
            ("one stray", [_alert_record("standup"), _alert_record("improv", "workshops")], 1),
            ("no categories", [{"recordName": "legacy", "fields": {}}], 1),
        ]
        for label, records, expected in cases:
            with self.subTest(label=label):
                self.urlopen.reset_mock()
                self.output, self.errors = io.StringIO(), io.StringIO()

                def answer(request, **kwargs):
                    if _is_query(request):
                        return _response({"records": records})
                    return self.acknowledge_subscription(request, **kwargs)

                self.urlopen.side_effect = answer
                self.assertEqual(self.run_main(probe), expected)
                self.assert_every_create_was_cleaned_up()
                stray = len(records) if label == "no categories" else expected
                self.assertIn(f"production / contains-any query: {len(records)} record(s) for "
                              f"['standup', 'writing_programs']; {stray} without a matching category",
                              self.output.getvalue())

    def test_malformed_contains_any_reply_fails_instead_of_passing_vacuously(self):
        diagnose.watcher.ENVIRONMENTS = ["production"]
        for payload in ({}, [], {"records": None},
                        {"records": [{"recordName": "x", "serverErrorCode": "ACCESS_DENIED"}]}):
            with self.subTest(payload=payload):
                self.urlopen.reset_mock()
                self.errors = io.StringIO()

                def answer(request, **kwargs):
                    if _is_query(request):
                        return _response(payload)
                    return self.acknowledge_subscription(request, **kwargs)

                self.urlopen.side_effect = answer
                self.assertEqual(self.run_main(probe), 1)
                self.assertIn("production / contains-any query FAILED", self.errors.getvalue())
                self.assert_every_create_was_cleaned_up()

    def test_contains_any_query_http_error_fails_but_subscriptions_are_still_cleaned_up(self):
        def answer(request, **kwargs):
            if _is_query(request) and "/development/" in request.full_url:
                raise urllib.error.HTTPError(request.full_url, 400, "Bad request", {},
                                             io.BytesIO(b'{"reason":"comparator not supported"}'))
            return self.acknowledge_subscription(request, **kwargs)

        self.urlopen.side_effect = answer
        self.assertEqual(self.run_main(probe), 1)
        self.assertEqual(self.urlopen.call_count, 18)
        self.assert_every_create_was_cleaned_up()
        self.assertIn("development / contains-any query: HTTP 400", self.errors.getvalue())
        self.assertIn("comparator not supported", self.errors.getvalue())
        # One environment's query failure does not skip the other's checks.
        self.assertIn("production / ucb-v3: subscription type accepted", self.output.getvalue())
        self.assertIn("production / contains-any query: 0 record(s)", self.output.getvalue())

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

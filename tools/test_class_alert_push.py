"""Send one production push to the server key owner's registered app devices.

Requires --send, or --cleanup-record to remove only a previous diagnostic
record without another push. A unique diagnostic school confines the alert to a temporary
subscription owned by that account; existing subscribers cannot match it.
Uses the app's exact UCB predicate and localized notification payload. Does
not change alert preferences, scan classes, or touch the watcher's state.
CloudKit acceptance does not establish device receipt: a person must confirm.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

from diagnose_class_alerts import query_body, watcher
from probe_class_alert_subscriptions import modify


def diagnostic_record_name(value: str) -> str:
    if not re.fullmatch(r"improv-diagnostic-[0-9a-f]{32}", value):
        raise ValueError("expected a locally generated improv-diagnostic-<32 lowercase hex digits> record name")
    return value


def modify_record(operation: str, record: dict) -> dict:
    if operation not in {"create", "forceDelete"}:
        raise ValueError("diagnostic records support only create and forceDelete")
    if operation == "forceDelete":
        # These UUIDs belong only to this tool. Unlike ordinary delete,
        # forceDelete needs no recordChangeTag, including after a lost create
        # response. Apple's delete request dictionary contains only recordName.
        record = {"recordName": diagnostic_record_name(record["recordName"])}
    subpath = f"/database/1/{watcher.CONTAINER}/production/public/records/modify"
    body = json.dumps({"operations": [{"operationType": operation, "record": record}]}).encode()
    request = urllib.request.Request(
        "https://api.apple-cloudkit.com" + subpath, data=body,
        headers=watcher._sign(subpath, body, "production"), method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        details = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"CloudKit {operation} HTTP {error.code}: {details[:1000]}") from error
    records = result.get("records") if isinstance(result, dict) else None
    matches = [r for r in (records or []) if isinstance(r, dict)
               and r.get("recordName") == record["recordName"]]
    if len(matches) != 1:
        raise ValueError("CloudKit did not acknowledge the diagnostic record")
    error = matches[0].get("serverErrorCode")
    if error and not (operation == "forceDelete" and error in {"NOT_FOUND", "UNKNOWN_ITEM"}):
        raise ValueError(f"{error}: {matches[0].get('reason', '')}")
    return matches[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--send", action="store_true",
                        help="send one real push only to the production server key owner's devices")
    action.add_argument("--cleanup-record", type=diagnostic_record_name, metavar="RECORD_NAME",
                        help="delete a previous UUID diagnostic record without sending another push")
    args = parser.parse_args(argv)
    if not watcher._key_id("production") or not watcher.PRIVATE_KEY_PEM:
        print("Production CloudKit credentials missing", file=sys.stderr)
        return 1
    if args.cleanup_record:
        try:
            modify_record("forceDelete", {"recordName": args.cleanup_record})
        except Exception as error:
            print(f"Cleanup FAILED for {args.cleanup_record}: {error}", file=sys.stderr, flush=True)
            return 1
        print(f"Diagnostic record removed or already absent: {args.cleanup_record}. No push sent.", flush=True)
        return 0
    unique = uuid.uuid4().hex
    subscription_id = "improv-diagnostic/" + unique
    record_name = "improv-diagnostic-" + unique
    school = "__improv_diagnostic_" + unique + "__"
    query = query_body("improv")["query"]
    query["filterBy"][0]["fieldValue"]["value"] = school
    subscription = {
        "subscriptionID": subscription_id, "subscriptionType": "query",
        "query": query, "firesOn": ["create"], "firesOnce": False, "zoneWide": True,
        "notificationInfo": {"titleLocalizationKey": "CA_TITLE",
                             "titleLocalizationArgs": ["pushTitle"],
                             "alertLocalizationKey": "CA_BODY",
                             "alertLocalizationArgs": ["pushBody"], "soundName": "default"}}
    record = {"recordType": "ClassAlert", "recordName": record_name, "fields": {
        "school": {"type": "STRING", "value": school},
        "category": {"type": "STRING", "value": "improv"},
        "categories": {"type": "STRING_LIST", "value": ["improv"]},
        "count": {"type": "INT64", "value": 0},
        "pushTitle": {"type": "STRING", "value": "Improv notification test"},
        "pushBody": {"type": "STRING", "value": "This is a test of UCB class alerts. Please confirm that it arrived."},
        "classIDs": {"type": "STRING", "value": ""}}}
    failed = False
    attempted_record = False
    print(f"Temporary subscription: {subscription_id}; record: {record_name}", flush=True)
    try:
        modify("production", "create", subscription)
        # Allow subscription indexing to settle before the matching create.
        time.sleep(10)
        attempted_record = True
        modify_record("create", record)
        print("CloudKit accepted the owner-only test alert. Awaiting device confirmation.", flush=True)
        # Leave the record available while CloudKit constructs the notification.
        time.sleep(45)
    except Exception as error:
        failed = True
        print(f"Owner push test FAILED: {error}", file=sys.stderr, flush=True)
    finally:
        # A lost response can hide a successful create: clean up only our
        # locally generated IDs even when acceptance was ambiguous.
        if attempted_record:
            try:
                modify_record("forceDelete", {"recordName": record_name})
                print("Temporary record removed", flush=True)
            except Exception as error:
                failed = True
                print(f"Cleanup FAILED for {record_name}: {error}", file=sys.stderr, flush=True)
        try:
            modify("production", "delete", {"subscriptionID": subscription_id})
            print("Temporary subscription removed", flush=True)
        except Exception as error:
            failed = True
            print(f"Cleanup FAILED for {subscription_id}: {error}", file=sys.stderr, flush=True)
    print("Success means CloudKit acceptance and cleanup, not confirmed push receipt.", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

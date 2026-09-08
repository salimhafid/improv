"""Send one production push to the server key owner's registered app devices.

Requires --send. A unique diagnostic school confines the alert to a temporary
subscription owned by that account; existing subscribers cannot match it.
Uses the app's exact UCB predicate and localized notification payload. Does
not change alert preferences, scan classes, or touch the watcher's state.
CloudKit acceptance does not establish device receipt: a person must confirm.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
import uuid

from diagnose_class_alerts import query_body, watcher
from probe_class_alert_subscriptions import modify


def modify_record(operation: str, record: dict) -> dict:
    subpath = f"/database/1/{watcher.CONTAINER}/production/public/records/modify"
    body = json.dumps({"operations": [{"operationType": operation, "record": record}]}).encode()
    request = urllib.request.Request(
        "https://api.apple-cloudkit.com" + subpath, data=body,
        headers=watcher._sign(subpath, body, "production"), method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    records = result.get("records") if isinstance(result, dict) else None
    matches = [r for r in (records or []) if isinstance(r, dict)
               and r.get("recordName") == record["recordName"]]
    if len(matches) != 1:
        raise ValueError("CloudKit did not acknowledge the diagnostic record")
    error = matches[0].get("serverErrorCode")
    if error and not (operation == "delete" and error in {"NOT_FOUND", "UNKNOWN_ITEM"}):
        raise ValueError(f"{error}: {matches[0].get('reason', '')}")
    return matches[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--send", action="store_true", required=True,
                        help="send one real push only to the production server key owner's devices")
    parser.parse_args(argv)
    if not watcher._key_id("production") or not watcher.PRIVATE_KEY_PEM:
        print("Production CloudKit credentials missing", file=sys.stderr)
        return 1
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
                modify_record("delete", {"recordType": "ClassAlert", "recordName": record_name})
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

"""Read-only checks for the CloudKit queries used by class-alert subscriptions.

Run through class-watch.yml mode=diagnose to use the existing server keys.
This does not create alerts, subscriptions, or watcher state. A successful
query verifies server authentication and query indexes, not device delivery.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import urllib.error
import urllib.request
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import watcher


def query_body(category: str | None = None) -> dict:
    filters = [{"fieldName": "school", "comparator": "EQUALS",
                "fieldValue": {"value": "ucb_ny", "type": "STRING"}}]
    if category is not None:
        filters.append({"fieldName": "categories", "comparator": "LIST_CONTAINS",
                        "fieldValue": {"value": category, "type": "STRING"}})
    return {"query": {"recordType": "ClassAlert", "filterBy": filters},
            "resultsLimit": 10,
            "desiredKeys": ["school", "category", "categories", "classIDs", "pushTitle"]}


def main() -> int:
    logging.basicConfig(level=logging.INFO)
    if not watcher.ENVIRONMENTS or not watcher.PRIVATE_KEY_PEM:
        print("ERROR: CloudKit credentials are missing; no checks performed.", file=sys.stderr)
        return 1
    failed = False
    for env in watcher.ENVIRONMENTS:
        if not watcher._key_id(env):
            print(f"{env}: CloudKit key ID is missing", file=sys.stderr)
            failed = True
            continue
        for label, category in [("school", None), ("UCB category", "improv")]:
            subpath = f"/database/1/{watcher.CONTAINER}/{env}/public/records/query"
            body = json.dumps(query_body(category)).encode()
            try:
                request = urllib.request.Request(
                    "https://api.apple-cloudkit.com" + subpath, data=body,
                    headers=watcher._sign(subpath, body, env), method="POST")
                with urllib.request.urlopen(request, timeout=30) as response:
                    result = json.load(response)
                if not isinstance(result, dict) or not isinstance(result.get("records"), list):
                    raise ValueError("CloudKit did not acknowledge the query with a records array")
                if any(record.get("serverErrorCode") for record in result["records"]):
                    raise ValueError("CloudKit returned a per-record query error")
                print(f"{env} / {label}: OK ({len(result['records'])} matching records returned)")
                for record in result["records"]:
                    fields = record.get("fields", {})
                    print(json.dumps({"recordName": record.get("recordName"),
                                      "fields": {key: fields[key].get("value") for key in
                                                 ("school", "category", "categories", "classIDs", "pushTitle")
                                                 if key in fields}}, ensure_ascii=False))
            except urllib.error.HTTPError as error:
                failed = True
                print(f"{env} / {label}: HTTP {error.code}: "
                      f"{error.read().decode('utf-8', errors='replace')[:1000]}", file=sys.stderr)
            except Exception as error:
                failed = True
                print(f"{env} / {label}: FAILED: {error}", file=sys.stderr)
        # Server keys act as their creating developer, not as every app user.
        # Only report aggregate configuration checks; never log account IDs,
        # device tokens, or the developer's individual notification choices.
        subpath = f"/database/1/{watcher.CONTAINER}/{env}/public/subscriptions/list"
        try:
            request = urllib.request.Request(
                "https://api.apple-cloudkit.com" + subpath,
                headers=watcher._sign(subpath, b"", env), method="GET")
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
            subscriptions = result.get("subscriptions") if isinstance(result, dict) else None
            if not isinstance(subscriptions, list):
                raise ValueError("CloudKit did not return a subscriptions array")
            ours = [sub for sub in subscriptions if sub.get("subscriptionID", "").startswith("alert/")]
            v2 = [sub for sub in ours if sub["subscriptionID"].startswith("alert/v2/")]
            alerts = [sub for sub in ours if
                      (sub.get("notificationInfo") or {}).get("alertBody") or
                      (sub.get("notificationInfo") or {}).get("alertLocalizationKey")]
            print(f"{env} / key owner's subscriptions: total={len(subscriptions)}, "
                  f"class_alerts={len(ours)}, ucb_v2={len(v2)}, visible_alerts={len(alerts)}")
            # Compare native subscription formats with the server probes
            # without exposing school/category choices, account IDs or tokens.
            shapes = Counter(json.dumps({
                "filters": sorted(f"{f.get('fieldName')}:{f.get('comparator')}"
                                  for f in (sub.get("query") or {}).get("filterBy", [])),
                "zoneWide": sub.get("zoneWide"),
                "zoneSpecified": bool(sub.get("zoneID")),
                "firesOn": sorted(sub.get("firesOn") or []),
                "firesOnce": sub.get("firesOnce"),
            }, sort_keys=True) for sub in ours)
            for shape, count in sorted(shapes.items()):
                print(f"{env} / subscription shape ({count}): {shape}")
            print("Subscription counts belong only to the server key's owner; other users may differ.")
        except urllib.error.HTTPError as error:
            print(f"{env} / key owner's subscriptions: unavailable (HTTP {error.code}): "
                  f"{error.read().decode('utf-8', errors='replace')[:1000]}", file=sys.stderr)
        except Exception as error:
            print(f"{env} / key owner's subscriptions: unavailable: {error}", file=sys.stderr)
    print("These checks do not verify a user's saved subscriptions, APNs registration, or push receipt.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

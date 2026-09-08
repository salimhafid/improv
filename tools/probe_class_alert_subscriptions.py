"""Verify the exact UCB query subscription type in development and production.

Creates a temporary subscription for an impossible school value, then removes
only that subscription. Does not create ClassAlert records or send pushes.
Development may learn the query subscription type, ready for schema promotion.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
import uuid

from diagnose_class_alerts import query_body, watcher


def modify(env: str, operation: str, subscription: dict) -> dict:
    subpath = f"/database/1/{watcher.CONTAINER}/{env}/public/subscriptions/modify"
    body = json.dumps({"operations": [{"operationType": operation,
                                       "subscription": subscription}]}).encode()
    request = urllib.request.Request(
        "https://api.apple-cloudkit.com" + subpath, data=body,
        headers=watcher._sign(subpath, body, env), method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    matches = [s for s in result.get("subscriptions", [])
               if s.get("subscriptionID") == subscription["subscriptionID"]]
    if len(matches) != 1:
        raise ValueError("CloudKit did not acknowledge the requested subscription")
    if matches[0].get("serverErrorCode"):
        raise ValueError(f"{matches[0]['serverErrorCode']}: {matches[0].get('reason', '')}")
    return matches[0]


def main() -> int:
    failed = False
    if not watcher.ENVIRONMENTS:
        print("ERROR: No CloudKit environments configured", file=sys.stderr)
        return 1
    for env in watcher.ENVIRONMENTS:
        if not watcher._key_id(env) or not watcher.PRIVATE_KEY_PEM:
            print(f"{env}: credentials missing", file=sys.stderr)
            failed = True
            continue
        subscription_id = "improv-diagnostic/" + uuid.uuid4().hex
        query = query_body("improv")["query"]
        query["filterBy"][0]["fieldValue"]["value"] = "__improv_diagnostic__"
        subscription = {
            "subscriptionID": subscription_id, "subscriptionType": "query",
            "query": query, "firesOn": ["create"], "firesOnce": False,
            "zoneWide": True,
            "notificationInfo": {"titleLocalizationKey": "CA_TITLE",
                                 "titleLocalizationArgs": ["pushTitle"],
                                 "alertLocalizationKey": "CA_BODY",
                                 "alertLocalizationArgs": ["pushBody"],
                                 "soundName": "default"}}
        created = False
        try:
            modify(env, "create", subscription)
            created = True
            print(f"{env}: exact UCB subscription type accepted")
        except urllib.error.HTTPError as error:
            failed = True
            print(f"{env}: subscription creation HTTP {error.code}: "
                  f"{error.read().decode('utf-8', errors='replace')[:1000]}", file=sys.stderr)
        except Exception as error:
            failed = True
            print(f"{env}: subscription creation FAILED: {error}", file=sys.stderr)
        finally:
            if created:
                try:
                    modify(env, "delete", {"subscriptionID": subscription_id})
                    print(f"{env}: temporary subscription removed")
                except Exception as error:
                    failed = True
                    print(f"{env}: cleanup FAILED for {subscription_id}: {error}", file=sys.stderr)
    print("No class records were created. Device push receipt remains a separate check.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

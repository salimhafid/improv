"""Verify every shipped app query subscription type in both environments.

Creates a temporary subscription for an impossible school value, then removes
only that subscription. Does not create ClassAlert records or send pushes.
Development may learn the school-only, legacy UCB scalar-category, and current
UCB list-category query types, ready for schema promotion.
The optional matrix also checks reversed filter order and explicit default-zone
scope. It diagnoses server validation differences, not the native app's scope.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
import uuid

from diagnose_class_alerts import query_body, watcher


QUERY_SHAPES = (
    ("school-only", None, None),
    ("ucb-legacy", "category", "EQUALS"),
    ("ucb-v2", "categories", "LIST_CONTAINS"),
)


class CloudKitSubscriptionError(ValueError):
    """A per-subscription failure acknowledged by CloudKit."""

    def __init__(self, code: str, reason: str, subscription_id: str):
        self.code = code
        self.reason = reason
        self.subscription_id = subscription_id
        super().__init__(f"{code}: {reason}")


def modify(env: str, operation: str, subscription: dict) -> dict:
    """Modify one subscription; deleting an already absent ID is a no-op.

    Callers can clean up their locally generated ID even after an ambiguous
    create response. Never substitute an ID from the server's response.
    """
    subpath = f"/database/1/{watcher.CONTAINER}/{env}/public/subscriptions/modify"
    body = json.dumps({"operations": [{"operationType": operation,
                                       "subscription": subscription}]}).encode()
    request = urllib.request.Request(
        "https://api.apple-cloudkit.com" + subpath, data=body,
        headers=watcher._sign(subpath, body, env), method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        if operation == "delete" and error.code == 404:
            return {}
        raise
    matches = [s for s in result.get("subscriptions", [])
               if s.get("subscriptionID") == subscription["subscriptionID"]]
    if len(matches) != 1:
        raise ValueError("CloudKit did not acknowledge the requested subscription")
    code = matches[0].get("serverErrorCode")
    if code:
        if operation == "delete" and code in {"UNKNOWN_ITEM", "NOT_FOUND"}:
            return {}
        raise CloudKitSubscriptionError(code, matches[0].get("reason", ""),
                                        subscription["subscriptionID"])
    return matches[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", action="store_true",
                        help="Probe both filter orders and all-zone/default-zone scopes")
    args = parser.parse_args(argv)
    variants = [(shape, field, comparator, reverse, zone_wide)
                for shape, field, comparator in QUERY_SHAPES
                for reverse in ((False, True) if args.matrix else (False,))
                for zone_wide in ((True, False) if args.matrix else (True,))]
    failed = False
    if not watcher.ENVIRONMENTS:
        print("ERROR: No CloudKit environments configured", file=sys.stderr)
        return 1
    for env in watcher.ENVIRONMENTS:
        if not watcher._key_id(env) or not watcher.PRIVATE_KEY_PEM:
            print(f"{env}: credentials missing", file=sys.stderr)
            failed = True
            continue
        for shape, category_field, comparator, reverse, zone_wide in variants:
            subscription_id = "improv-diagnostic/" + uuid.uuid4().hex
            query = query_body()["query"]
            query["filterBy"][0]["fieldValue"]["value"] = "__improv_diagnostic__"
            if category_field is not None:
                query["filterBy"].append({"fieldName": category_field, "comparator": comparator,
                                          "fieldValue": {"value": "improv", "type": "STRING"}})
            if reverse:
                query["filterBy"].reverse()
            subscription = {
                "subscriptionID": subscription_id, "subscriptionType": "query",
                "query": query, "firesOn": ["create"], "firesOnce": False,
                "zoneWide": zone_wide,
                "notificationInfo": {"titleLocalizationKey": "CA_TITLE",
                                     "titleLocalizationArgs": ["pushTitle"],
                                     "alertLocalizationKey": "CA_BODY",
                                     "alertLocalizationArgs": ["pushBody"],
                                     "soundName": "default"}}
            if not zone_wide:
                subscription["zoneID"] = {"zoneName": "_defaultZone"}
            label = f"{env} / {shape}"
            if args.matrix:
                order = "reversed" if reverse else "school-first"
                scope = "all-zones" if zone_wide else "default-zone"
                label += f" / {order} / {scope}"
            try:
                modify(env, "create", subscription)
                print(f"{label}: subscription type accepted")
            except urllib.error.HTTPError as error:
                failed = True
                print(f"{label}: subscription creation HTTP {error.code}: "
                      f"{error.read().decode('utf-8', errors='replace')[:1000]} "
                      f"(subscription {subscription_id})", file=sys.stderr)
            except Exception as error:
                failed = True
                print(f"{label}: subscription creation FAILED: {error} "
                      f"(subscription {subscription_id})", file=sys.stderr)
            finally:
                # The server may have committed a create whose reply was lost or
                # malformed. This ID was generated by us, so cleanup is safe even
                # without an acknowledgment; an already absent ID is harmless.
                try:
                    modify(env, "delete", {"subscriptionID": subscription_id})
                    print(f"{label}: temporary subscription removed or already absent")
                except Exception as error:
                    failed = True
                    print(f"{label}: cleanup FAILED for {subscription_id}: {error}", file=sys.stderr)
    print("No class records were created. Device push receipt remains a separate check.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

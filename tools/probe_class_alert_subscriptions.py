"""Verify every shipped app query subscription type in both environments.

Creates a temporary subscription for an impossible school value, then removes
only that subscription. Does not create ClassAlert records or send pushes.
Development may learn the school-only, legacy UCB scalar-category (ucb-legacy),
per-category list-membership (ucb-v2, LIST_CONTAINS) and per-school
any-of-the-picks (ucb-v3, LIST_CONTAINS_ANY with a STRING_LIST value) query
types, ready for schema promotion.
Without --matrix it also runs one read-only LIST_CONTAINS_ANY query per
environment against real UCB NY alert records and fails if any returned
record shares none of the queried categories (ucb-v3 relies on "shares any").
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
    # 1.7+: one subscription per school, `ANY categories IN picks`, which the
    # native client sends as listContainsAny — one push per class however many
    # of the user's categories it carries.
    ("ucb-v3", "categories", "LIST_CONTAINS_ANY"),
)


def category_filter_value(comparator: str) -> dict:
    """LIST_CONTAINS_ANY takes the user's picks as a list; the others one value."""
    if comparator == "LIST_CONTAINS_ANY":
        return {"value": ["improv", "standup"], "type": "STRING_LIST"}
    return {"value": "improv", "type": "STRING"}


def class_alert_notification_info() -> dict:
    """Use CloudKit's REST title keys, which differ from the Swift SDK names.

    Native subscription responses use titleLocalizedKey/Arguments. Sending
    titleLocalizationKey/Args can omit the title argument from the learned
    subscription schema, leaving native production creates unable to use it.
    """
    return {"titleLocalizedKey": "CA_TITLE",
            "titleLocalizedArguments": ["pushTitle"],
            "alertLocalizationKey": "CA_BODY",
            "alertLocalizationArgs": ["pushBody"],
            "soundName": "default"}


def validate_notification_info(subscription: dict) -> None:
    """Reject accepted subscriptions whose normalized payload lost any field."""
    info = subscription.get("notificationInfo")
    if not isinstance(info, dict):
        raise ValueError("CloudKit did not return notificationInfo")
    for key, expected in class_alert_notification_info().items():
        if info.get(key) != expected:
            raise ValueError(f"CloudKit did not retain notificationInfo.{key}")


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


def check_contains_any_query(env: str) -> bool:
    """Read-only: does the server evaluate LIST_CONTAINS_ANY as "shares any
    value"? Queries real UCB NY alert records; writes nothing."""
    picks = ["standup", "writing_programs"]
    body = query_body()
    body["query"]["filterBy"].append({"fieldName": "categories", "comparator": "LIST_CONTAINS_ANY",
                                      "fieldValue": {"value": picks, "type": "STRING_LIST"}})
    body["resultsLimit"] = 50
    subpath = f"/database/1/{watcher.CONTAINER}/{env}/public/records/query"
    raw = json.dumps(body).encode()
    request = urllib.request.Request("https://api.apple-cloudkit.com" + subpath, data=raw,
                                     headers=watcher._sign(subpath, raw, env), method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        # A reply without a records array would otherwise pass as "0 records,
        # none stray", and an errored record would be misreported as stray.
        records = result.get("records") if isinstance(result, dict) else None
        if not isinstance(records, list):
            raise ValueError("CloudKit did not acknowledge the query with a records array")
        if any(not isinstance(r, dict) or r.get("serverErrorCode") for r in records):
            raise ValueError("CloudKit returned a per-record query error")
    except urllib.error.HTTPError as error:
        print(f"{env} / contains-any query: HTTP {error.code}: "
              f"{error.read().decode('utf-8', errors='replace')[:600]}", file=sys.stderr)
        return False
    except Exception as error:  # noqa: BLE001
        print(f"{env} / contains-any query FAILED: {error}", file=sys.stderr)
        return False
    sets = [((r.get("fields") or {}).get("categories") or {}).get("value") or [] for r in records]
    stray = [c for c in sets if not set(c) & set(picks)]
    print(f"{env} / contains-any query: {len(records)} record(s) for {picks}; "
          f"{len(stray)} without a matching category; e.g. {sets[:3]}")
    return not stray


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
                                          "fieldValue": category_filter_value(comparator)})
            if reverse:
                query["filterBy"].reverse()
            subscription = {
                "subscriptionID": subscription_id, "subscriptionType": "query",
                "query": query, "firesOn": ["create"], "firesOnce": False,
                "zoneWide": zone_wide,
                "notificationInfo": class_alert_notification_info()}
            if not zone_wide:
                subscription["zoneID"] = {"zoneName": "_defaultZone"}
            label = f"{env} / {shape}"
            if args.matrix:
                order = "reversed" if reverse else "school-first"
                scope = "all-zones" if zone_wide else "default-zone"
                label += f" / {order} / {scope}"
            try:
                created = modify(env, "create", subscription)
                validate_notification_info(created)
                print(f"{label}: subscription type accepted; title/body payload verified")
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
        if not args.matrix and not check_contains_any_query(env):
            failed = True
    print("No class records were created. Device push receipt remains a separate check.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

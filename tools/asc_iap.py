"""App Store Connect setup for the Class Alerts in-app purchase (non-consumable,
USD 9.99) — what the web UI's "In-App Purchases" page does, from the CLI.

Uses the same key setup as asc_pass_cert.py (ASC_ISSUER_ID, ASC_KEY_ID,
ASC_KEY_PATH; Admin key). Run from the repo root with the project venv:

    .venv/bin/python tools/asc_iap.py status [--product-id ID]
    .venv/bin/python tools/asc_iap.py create --screenshot shot.png [--dry-run]

`status` is read-only. `create` is idempotent: it finds the IAP by product id
(or creates it) and then fills in only what is missing or different — the
en-US localization, the USD price schedule, worldwide availability, the App
Review note and the App Review screenshot. `--dry-run` still sends the GETs
(so it reports what exists) but prints every write instead of sending it.

The IAP is not submitted here: Apple requires an app's first in-app purchase
to go to review together with an app version (add it on the version page).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import date
from decimal import Decimal, InvalidOperation

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_pass_cert import token  # noqa: E402

APP_ID = "6789625355"
PRODUCT_ID = "com.salimhafid.UCBShows.classalerts"
REFERENCE_NAME = "Class Alerts"
PRICE = "9.99"

BASE_TERRITORY = "USA"
LOCALE = "en-US"
DISPLAY_NAME = "Class Alerts"  # Apple caps the IAP display name at 30 characters
DESCRIPTION = "Alerts when schools post new classes"  # and the description at 45
REVIEW_NOTE = ("Unlocks Class Alerts: push notifications when improv schools post new classes. "
               "Open the Classes tab, tap the bell. Existing users who installed before version 1.8 "
               "keep the feature free.")

# call() in asc_pass_cert.py is pinned to /v1; the IAP API spans /v1 and /v2,
# so paths here carry their version and the host is joined on.
HOST = "https://api.appstoreconnect.apple.com"
# Stands in for the id of an IAP that --dry-run did not create; GETs under it
# are answered as "nothing there" instead of being sent.
NEW_IAP = "<new-iap-id>"
# JSON:API local id linking the schedule's manualPrices to its included price.
PRICE_LOCAL_ID = "${price-usa}"


def _apple_error(raw: bytes) -> str:
    """Apple's error titles/details, falling back to the raw body."""
    try:
        errors = json.loads(raw).get("errors") or []
        text = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errors)
    except (ValueError, AttributeError):
        text = ""
    return text or raw.decode(errors="replace")[:800]


class Api:
    """Thin ASC client. GETs always go out; writes are printed, not sent, on a dry run."""

    def __init__(self, dry_run: bool = False):
        self.dry_run = dry_run

    def request(self, method: str, path: str, body: dict | None = None, missing_ok: bool = False) -> dict | None:
        url = path if path.startswith("https://") else HOST + path
        req = urllib.request.Request(url, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {token()}",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if missing_ok and e.code == 404:
                return None
            raise SystemExit(f"HTTP {e.code} {method} {path}: {_apple_error(e.read())}")
        except urllib.error.URLError as e:
            raise SystemExit(f"{method} {path}: {e.reason}")

    def get(self, path: str, missing_ok: bool = False) -> dict | None:
        if NEW_IAP in path:
            return None
        return self.request("GET", path, missing_ok=missing_ok)

    def pages(self, path: str):
        """Yields each page, following links.next (an absolute URL)."""
        if NEW_IAP in path:
            return
        while path:
            page = self.request("GET", path) or {}
            yield page
            path = (page.get("links") or {}).get("next")

    def get_all(self, path: str) -> tuple[list, list]:
        data: list = []
        included: list = []
        for page in self.pages(path):
            data += page.get("data") or []
            included += page.get("included") or []
        return data, included

    def did(self, done: str, planned: str) -> str:
        """Step outcome wording: what happened, or on a dry run what would."""
        return planned if self.dry_run else done

    def write(self, method: str, path: str, body: dict | None = None) -> dict | None:
        if self.dry_run:
            print(f"DRY-RUN {method} {path}" + (f" {json.dumps(body)}" if body is not None else ""))
            return None
        return self.request(method, path, body)


def _rel(resource: dict, name: str):
    """A to-one relationship's id, or None."""
    data = ((resource.get("relationships") or {}).get(name) or {}).get("data")
    return data.get("id") if isinstance(data, dict) else None


def _same_price(a, b) -> bool:
    try:
        return Decimal(str(a)) == Decimal(str(b))
    except InvalidOperation:
        return False


# ── reads ─────────────────────────────────────────────────────────────────

def find_iap(api: Api, product_id: str = PRODUCT_ID) -> dict | None:
    data, _ = api.get_all(f"/v1/apps/{APP_ID}/inAppPurchasesV2?filter[productId]={product_id}&limit=200")
    return next((i for i in data if i["attributes"].get("productId") == product_id), None)


def localizations(api: Api, iap_id: str) -> list:
    return api.get_all(f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations?limit=200")[0]


def manual_prices(api: Api, iap_id: str) -> list[dict]:
    """The schedule's manual prices as {territory, customerPrice, currency, startDate, endDate}."""
    sched = api.get(f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule", missing_ok=True)
    if not sched or not sched.get("data"):
        return []
    data, included = api.get_all(f"/v1/inAppPurchasePriceSchedules/{sched['data']['id']}/manualPrices"
                                 "?include=inAppPurchasePricePoint,territory&limit=200")
    points = {i["id"]: i.get("attributes") or {} for i in included if i["type"] == "inAppPurchasePricePoints"}
    territories = {i["id"]: i.get("attributes") or {} for i in included if i["type"] == "territories"}
    out = []
    for p in data:
        territory = _rel(p, "territory")
        attrs = p.get("attributes") or {}
        out.append({"territory": territory,
                    "customerPrice": points.get(_rel(p, "inAppPurchasePricePoint"), {}).get("customerPrice"),
                    "currency": territories.get(territory, {}).get("currency"),
                    "startDate": attrs.get("startDate"), "endDate": attrs.get("endDate")})
    return out


def _is_current(price: dict, today: str) -> bool:
    return (price["startDate"] or "") <= today and (price["endDate"] is None or price["endDate"] > today)


def find_price_point(api: Api, iap_id: str, territory: str = BASE_TERRITORY, price: str = PRICE) -> str | None:
    """Pages through the territory's price points until one costs `price`."""
    for page in api.pages(f"/v2/inAppPurchases/{iap_id}/pricePoints?filter[territory]={territory}&limit=200"):
        for point in page.get("data") or []:
            if _same_price((point.get("attributes") or {}).get("customerPrice"), price):
                return point["id"]
    return None


def availability(api: Api, iap_id: str) -> tuple[dict | None, set]:
    """The availability resource (or None) and its territory ids."""
    res = api.get(f"/v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability", missing_ok=True)
    if not res or not res.get("data"):
        return None, set()
    data, _ = api.get_all(f"/v1/inAppPurchaseAvailabilities/{res['data']['id']}/availableTerritories?limit=200")
    return res["data"], {t["id"] for t in data}


def review_screenshot(api: Api, iap_id: str) -> dict | None:
    res = api.get(f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot", missing_ok=True)
    return (res or {}).get("data")


def _shot_state(shot: dict) -> str | None:
    return ((shot.get("attributes") or {}).get("assetDeliveryState") or {}).get("state")


# ── create steps ──────────────────────────────────────────────────────────

def ensure_iap(api: Api) -> tuple[dict, bool]:
    """The IAP resource and whether it already existed."""
    iap = find_iap(api)
    if iap:
        a = iap["attributes"]
        print(f"IAP: exists {iap['id']} {a.get('productId')} {a.get('inAppPurchaseType')} state={a.get('state')}")
        return iap, True
    out = api.write("POST", "/v2/inAppPurchases", {"data": {
        "type": "inAppPurchases",
        "attributes": {"name": REFERENCE_NAME, "productId": PRODUCT_ID, "inAppPurchaseType": "NON_CONSUMABLE",
                       "reviewNote": REVIEW_NOTE, "familySharable": False},
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    if out is None:
        print(f"IAP: would create {PRODUCT_ID}")
        return {"id": NEW_IAP, "attributes": {"reviewNote": REVIEW_NOTE, "familySharable": False}}, False
    iap = out["data"]
    print(f"IAP: created {iap['id']} {PRODUCT_ID} state={iap['attributes'].get('state')}")
    return iap, False


def ensure_review_note(api: Api, iap: dict) -> None:
    a = iap.get("attributes") or {}
    if a.get("familySharable"):
        print("WARNING: Family Sharing is on for this IAP and Apple does not allow turning it off")
    if (a.get("reviewNote") or "") == REVIEW_NOTE:
        print("review note: ok")
        return
    api.write("PATCH", f"/v2/inAppPurchases/{iap['id']}", {"data": {
        "type": "inAppPurchases", "id": iap["id"], "attributes": {"reviewNote": REVIEW_NOTE}}})
    print(f"review note: {api.did('updated', 'would update')}")


def ensure_localization(api: Api, iap_id: str) -> None:
    want = {"name": DISPLAY_NAME, "description": DESCRIPTION}
    loc = next((l for l in localizations(api, iap_id) if l["attributes"].get("locale") == LOCALE), None)
    if loc and all(loc["attributes"].get(k) == v for k, v in want.items()):
        print(f"localization {LOCALE}: ok")
        return
    if loc:
        api.write("PATCH", f"/v1/inAppPurchaseLocalizations/{loc['id']}", {"data": {
            "type": "inAppPurchaseLocalizations", "id": loc["id"], "attributes": want}})
        print(f"localization {LOCALE}: {api.did('updated', 'would update')}")
        return
    api.write("POST", "/v1/inAppPurchaseLocalizations", {"data": {
        "type": "inAppPurchaseLocalizations",
        "attributes": {"locale": LOCALE, **want},
        "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}})
    print(f"localization {LOCALE}: {api.did('created', 'would create')}")


def ensure_price(api: Api, iap_id: str) -> None:
    today = date.today().isoformat()
    if any(p["territory"] == BASE_TERRITORY and _same_price(p["customerPrice"], PRICE) and _is_current(p, today)
           for p in manual_prices(api, iap_id)):
        print(f"price: ok ({BASE_TERRITORY} {PRICE})")
        return
    point = find_price_point(api, iap_id)
    if point is None:
        if iap_id != NEW_IAP:
            raise SystemExit(f"price: no {BASE_TERRITORY} price point at {PRICE}")
        point = f"<{BASE_TERRITORY} {PRICE} price point id>"
    api.write("POST", "/v1/inAppPurchasePriceSchedules", {
        "data": {"type": "inAppPurchasePriceSchedules", "relationships": {
            "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
            "baseTerritory": {"data": {"type": "territories", "id": BASE_TERRITORY}},
            "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": PRICE_LOCAL_ID}]}}},
        "included": [{"type": "inAppPurchasePrices", "id": PRICE_LOCAL_ID,
                      "attributes": {"startDate": None},
                      "relationships": {
                          "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}},
                          "inAppPurchasePricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": point}}}}]})
    print(f"price: {api.did('set', 'would set')} {BASE_TERRITORY} {PRICE} (price point {point}); "
          "other territories follow Apple's equalization")


def ensure_availability(api: Api, iap_id: str) -> None:
    every = [t["id"] for t in api.get_all("/v1/territories?limit=200")[0]]
    current, have = availability(api, iap_id)
    if current and (current.get("attributes") or {}).get("availableInNewTerritories") and have >= set(every):
        print(f"availability: ok ({len(have)} territories + new ones)")
        return
    api.write("POST", "/v1/inAppPurchaseAvailabilities", {"data": {
        "type": "inAppPurchaseAvailabilities",
        "attributes": {"availableInNewTerritories": True},
        "relationships": {
            "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
            "availableTerritories": {"data": [{"type": "territories", "id": t} for t in every]}}}})
    print(f"availability: {api.did('set', 'would set')} {len(every)} territories + new ones")


def _upload(op: dict, data: bytes) -> None:
    """One upload operation: its byte range, its method and Apple's headers (no JWT)."""
    chunk = data[op["offset"]:op["offset"] + op["length"]]
    headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
    req = urllib.request.Request(op["url"], data=chunk, method=op.get("method") or "PUT", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120):
            pass
    except urllib.error.HTTPError as e:
        raise SystemExit(f"screenshot upload: HTTP {e.code} {op.get('method')} {op['url']}: {_apple_error(e.read())}")
    except urllib.error.URLError as e:
        raise SystemExit(f"screenshot upload: {e.reason}")


def ensure_screenshot(api: Api, iap_id: str, path: str) -> None:
    shot = review_screenshot(api, iap_id)
    if shot:
        state = _shot_state(shot)
        if state == "COMPLETE":
            print(f"review screenshot: ok ({shot['attributes'].get('fileName')})")
            return
        if state == "UPLOAD_COMPLETE":
            print("review screenshot: uploaded, Apple is still processing it — check `status` later")
            return
        # AWAITING_UPLOAD (an interrupted upload) or FAILED: replace it.
        api.write("DELETE", f"/v1/inAppPurchaseAppStoreReviewScreenshots/{shot['id']}")
        print(f"review screenshot: {api.did('removed', 'would remove')} the {state} one")
    with open(path, "rb") as f:
        data = f.read()
    res = api.write("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots",
        "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
        "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}})
    checksum = hashlib.md5(data).hexdigest()
    if res is None:
        print(f"DRY-RUN PUT the {len(data)} bytes to each returned upload operation")
        api.write("PATCH", "/v1/inAppPurchaseAppStoreReviewScreenshots/<reserved-id>", {"data": {
            "type": "inAppPurchaseAppStoreReviewScreenshots", "id": "<reserved-id>",
            "attributes": {"uploaded": True, "sourceFileChecksum": checksum}}})
        return
    shot_id = res["data"]["id"]
    ops = res["data"]["attributes"].get("uploadOperations") or []
    for op in ops:
        _upload(op, data)
    done = api.write("PATCH", f"/v1/inAppPurchaseAppStoreReviewScreenshots/{shot_id}", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots", "id": shot_id,
        "attributes": {"uploaded": True, "sourceFileChecksum": checksum}}})
    print(f"review screenshot: uploaded {os.path.basename(path)} in {len(ops)} part(s), "
          f"state={_shot_state(done['data']) if done else None}")


def create(api: Api, screenshot: str) -> None:
    iap, existed = ensure_iap(api)
    iap_id = iap["id"]
    ensure_localization(api, iap_id)
    ensure_price(api, iap_id)
    ensure_availability(api, iap_id)
    if existed:  # a new IAP got the note in its create body
        ensure_review_note(api, iap)
    ensure_screenshot(api, iap_id, screenshot)
    print("done" + (" (dry run: nothing was written)" if api.dry_run else ""))


# ── status ────────────────────────────────────────────────────────────────

def status(api: Api, product_id: str) -> None:
    iaps, _ = api.get_all(f"/v1/apps/{APP_ID}/inAppPurchasesV2?limit=200")
    print(f"app {APP_ID}: {len(iaps)} in-app purchase(s)")
    for i in iaps:
        a = i["attributes"]
        print(f"  {i['id']}  {a.get('productId')}  {a.get('inAppPurchaseType')}  {a.get('state')}  \"{a.get('name')}\"")
    iap = next((i for i in iaps if i["attributes"].get("productId") == product_id), None)
    if not iap:
        print(f"{product_id}: not created yet")
        return
    a, iap_id = iap["attributes"], iap["id"]
    print(f"{product_id} ({iap_id}): state={a.get('state')} familySharable={a.get('familySharable')}")
    print(f"  review note: {a.get('reviewNote')!r}")
    locs = localizations(api, iap_id)
    for l in locs:
        la = l["attributes"]
        print(f"  localization {la.get('locale')}: \"{la.get('name')}\" / \"{la.get('description')}\" state={la.get('state')}")
    if not locs:
        print("  localizations: none")
    prices = manual_prices(api, iap_id)
    for p in prices:
        when = f" from {p['startDate']}" if p["startDate"] else ""
        until = f" until {p['endDate']}" if p["endDate"] else ""
        print(f"  manual price: {p['territory']} {p['customerPrice']} {p['currency'] or ''}{when}{until}".rstrip())
    if not prices:
        print("  price schedule: none")
    current, territories = availability(api, iap_id)
    if current:
        print(f"  availability: {len(territories)} territories, "
              f"availableInNewTerritories={(current.get('attributes') or {}).get('availableInNewTerritories')}")
    else:
        print("  availability: not set")
    shot = review_screenshot(api, iap_id)
    if shot:
        sa = shot.get("attributes") or {}
        errors = ((sa.get("assetDeliveryState") or {}).get("errors") or [])
        print(f"  review screenshot: {sa.get('fileName')} state={_shot_state(shot)}"
              + "".join(f" error={e.get('code')}: {e.get('description')}" for e in errors))
    else:
        print("  review screenshot: none")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("status", help="read-only report")
    st.add_argument("--product-id", default=PRODUCT_ID)
    cr = sub.add_parser("create", help="find-or-create and complete the IAP (idempotent)")
    cr.add_argument("--screenshot", required=True, help="App Review screenshot (PNG/JPEG of the paywall)")
    cr.add_argument("--dry-run", action="store_true", help="send GETs only; print the writes")
    args = parser.parse_args(argv)
    missing = [k for k in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_KEY_PATH") if not os.environ.get(k)]
    if missing:
        raise SystemExit(f"set {', '.join(missing)} (an Admin App Store Connect API key)")
    if args.cmd == "status":
        status(Api(), args.product_id)
        return 0
    if not os.path.isfile(args.screenshot):
        raise SystemExit(f"screenshot not found: {args.screenshot}")
    create(Api(dry_run=args.dry_run), args.screenshot)
    return 0


if __name__ == "__main__":
    sys.exit(main())

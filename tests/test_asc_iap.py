"""Offline tests for tools/asc_iap.py (the Class Alerts in-app purchase setup).

Every HTTP request goes through a fake urlopen that answers from a fixed route
table and records what was sent, so the real request construction is exercised
without touching App Store Connect. The request shapes asserted in SPEC_CREATE
come from Apple's App Store Connect OpenAPI spec (4.5.1).
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

_TOOL = Path(__file__).resolve().parents[1] / "tools" / "asc_iap.py"
_spec = importlib.util.spec_from_file_location("asc_iap", _TOOL)
asc_iap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(asc_iap)

HOST = asc_iap.HOST
IAP = "IAP1"
APPS_LIST = f"/v1/apps/{asc_iap.APP_ID}/inAppPurchasesV2?filter[productId]={asc_iap.PRODUCT_ID}&limit=200"
LOCS = f"/v2/inAppPurchases/{IAP}/inAppPurchaseLocalizations?limit=200"
SCHEDULE = f"/v2/inAppPurchases/{IAP}/iapPriceSchedule"
MANUAL = f"/v1/inAppPurchasePriceSchedules/{IAP}/manualPrices?include=inAppPurchasePricePoint,territory&limit=200"
POINTS = f"/v2/inAppPurchases/{IAP}/pricePoints?filter[territory]=USA&limit=200"
POINTS_2 = f"/v2/inAppPurchases/{IAP}/pricePoints?cursor=Mg&filter[territory]=USA&limit=200"
TERRITORIES = "/v1/territories?limit=200"
TERRITORIES_2 = "/v1/territories?cursor=Mg&limit=200"
AVAIL = f"/v2/inAppPurchases/{IAP}/inAppPurchaseAvailability"
AVAIL_TERRITORIES = "/v1/inAppPurchaseAvailabilities/AV1/availableTerritories?limit=200"
SHOT = f"/v2/inAppPurchases/{IAP}/appStoreReviewScreenshot"
UPLOAD_A = "https://upload.example.com/part-a"
UPLOAD_B = "https://upload.example.com/part-b"

# Create requests per Apple's spec: resource type, required attributes, every
# attribute the schema allows, and required relationships → related type.
SPEC_CREATE = {
    "/v2/inAppPurchases": ("inAppPurchases", {"name", "productId", "inAppPurchaseType"},
                           {"name", "productId", "inAppPurchaseType", "reviewNote", "familySharable"},
                           {"app": "apps"}),
    "/v1/inAppPurchaseLocalizations": ("inAppPurchaseLocalizations", {"name", "locale"},
                                       {"name", "locale", "description"},
                                       {"inAppPurchaseV2": "inAppPurchases"}),
    "/v1/inAppPurchasePriceSchedules": ("inAppPurchasePriceSchedules", set(), set(),
                                        {"inAppPurchase": "inAppPurchases", "baseTerritory": "territories",
                                         "manualPrices": "inAppPurchasePrices"}),
    "/v1/inAppPurchaseAvailabilities": ("inAppPurchaseAvailabilities", {"availableInNewTerritories"},
                                        {"availableInNewTerritories"},
                                        {"inAppPurchase": "inAppPurchases", "availableTerritories": "territories"}),
    "/v1/inAppPurchaseAppStoreReviewScreenshots": ("inAppPurchaseAppStoreReviewScreenshots",
                                                   {"fileName", "fileSize"}, {"fileName", "fileSize"},
                                                   {"inAppPurchaseV2": "inAppPurchases"}),
}


def _error(status, title, detail):
    return ("error", status, {"errors": [{"status": str(status), "code": "X", "title": title, "detail": detail}]})


NOT_FOUND = _error(404, "The specified resource does not exist", "none")


class FakeASC:
    """Answers intercepted urllib requests from {(method, path-or-url): payload}."""

    def __init__(self, routes):
        self.routes = routes
        self.requests = []

    def __call__(self, req, timeout=None):
        url = req.full_url
        path = url[len(HOST):] if url.startswith(HOST) else url
        raw = req.data
        self.requests.append(SimpleNamespace(
            method=req.get_method(), path=path, raw=raw,
            body=json.loads(raw) if raw and url.startswith(HOST) else None,
            headers={k.lower(): v for k, v in req.header_items()}))
        key = (req.get_method(), path)
        if key not in self.routes:
            raise AssertionError(f"unexpected request {key}")
        resp = self.routes[key]
        if isinstance(resp, tuple) and resp[0] == "error":
            raise urllib.error.HTTPError(url, resp[1], "error", {}, io.BytesIO(json.dumps(resp[2]).encode()))
        return io.BytesIO(json.dumps(resp).encode() if resp is not None else b"")

    def calls(self):
        return [(r.method, r.path) for r in self.requests]

    def writes(self):
        return [r for r in self.requests if r.method != "GET"]

    def body(self, method, path):
        return next(r.body for r in self.requests if (r.method, r.path) == (method, path))


def _point(pid, price):
    return {"type": "inAppPurchasePricePoints", "id": pid, "attributes": {"customerPrice": price, "proceeds": "x"}}


def _territories(*ids):
    return [{"type": "territories", "id": t, "attributes": {"currency": "USD"}} for t in ids]


def _existing_iap(**attrs):
    a = {"productId": asc_iap.PRODUCT_ID, "name": "Class Alerts", "inAppPurchaseType": "NON_CONSUMABLE",
         "state": "READY_TO_SUBMIT", "reviewNote": asc_iap.REVIEW_NOTE, "familySharable": False}
    a.update(attrs)
    return {"data": [{"type": "inAppPurchases", "id": IAP, "attributes": a}]}


def _common_reads():
    """Territories (two pages) and the price points (two pages; 9.99 on page 2)."""
    return {
        ("GET", TERRITORIES): {"data": _territories("AFG", "USA"), "links": {"next": HOST + TERRITORIES_2}},
        ("GET", TERRITORIES_2): {"data": _territories("ZWE")},
        ("GET", POINTS): {"data": [_point("PP-099", "0.99"), _point("PP-999X", "99.9")],
                          "links": {"next": HOST + POINTS_2}},
        ("GET", POINTS_2): {"data": [_point("PP-949", "9.49"), _point("PP-999", "9.99"), _point("PP-1099", "10.99")]},
    }


def _fresh_routes():
    routes = _common_reads()
    routes.update({
        ("GET", APPS_LIST): {"data": []},
        ("POST", "/v2/inAppPurchases"): {"data": {"type": "inAppPurchases", "id": IAP,
                                                  "attributes": {"productId": asc_iap.PRODUCT_ID,
                                                                 "state": "MISSING_METADATA"}}},
        ("GET", LOCS): {"data": []},
        ("POST", "/v1/inAppPurchaseLocalizations"): {"data": {"type": "inAppPurchaseLocalizations", "id": "L1"}},
        ("GET", SCHEDULE): NOT_FOUND,
        ("POST", "/v1/inAppPurchasePriceSchedules"): {"data": {"type": "inAppPurchasePriceSchedules", "id": IAP}},
        ("GET", AVAIL): NOT_FOUND,
        ("POST", "/v1/inAppPurchaseAvailabilities"): {"data": {"type": "inAppPurchaseAvailabilities", "id": "AV1"}},
        ("GET", SHOT): {"data": None},
        ("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots"): {"data": {
            "type": "inAppPurchaseAppStoreReviewScreenshots", "id": "S1",
            "attributes": {"uploadOperations": [
                {"method": "PUT", "url": UPLOAD_A, "offset": 0, "length": 4,
                 "requestHeaders": [{"name": "Content-Type", "value": "image/png"},
                                    {"name": "x-apple-upload-token", "value": "tok-a"}]},
                {"method": "PUT", "url": UPLOAD_B, "offset": 4, "length": 6,
                 "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]}]}}},
        ("PUT", UPLOAD_A): None,
        ("PUT", UPLOAD_B): None,
        ("PATCH", "/v1/inAppPurchaseAppStoreReviewScreenshots/S1"): {"data": {
            "type": "inAppPurchaseAppStoreReviewScreenshots", "id": "S1",
            "attributes": {"assetDeliveryState": {"state": "UPLOAD_COMPLETE"}}}},
    })
    return routes


def _complete_routes(**iap_attrs):
    routes = _common_reads()
    routes.update({
        ("GET", APPS_LIST): _existing_iap(**iap_attrs),
        ("GET", LOCS): {"data": [{"type": "inAppPurchaseLocalizations", "id": "L1", "attributes": {
            "locale": "en-US", "name": asc_iap.DISPLAY_NAME, "description": asc_iap.DESCRIPTION}}]},
        ("GET", SCHEDULE): {"data": {"type": "inAppPurchasePriceSchedules", "id": IAP}},
        ("GET", MANUAL): {
            "data": [{"type": "inAppPurchasePrices", "id": "PR1",
                      "attributes": {"startDate": None, "endDate": None, "manual": True},
                      "relationships": {
                          "inAppPurchasePricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": "PP-999"}},
                          "territory": {"data": {"type": "territories", "id": "USA"}}}}],
            "included": [_point("PP-999", "9.99"), *_territories("USA")]},
        ("GET", AVAIL): {"data": {"type": "inAppPurchaseAvailabilities", "id": "AV1",
                                  "attributes": {"availableInNewTerritories": True}}},
        ("GET", AVAIL_TERRITORIES): {"data": _territories("AFG", "USA", "ZWE")},
        ("GET", SHOT): {"data": {"type": "inAppPurchaseAppStoreReviewScreenshots", "id": "S0", "attributes": {
            "fileName": "paywall.png", "assetDeliveryState": {"state": "COMPLETE"}}}},
    })
    return routes


SHOT_BYTES = b"\x89PNG\r\n\x1a\nAB"  # 10 bytes: split 4 + 6 by the fake upload operations


class AscIapTests(unittest.TestCase):
    def setUp(self):
        fd, self.shot = tempfile.mkstemp(suffix=".png")
        with os.fdopen(fd, "wb") as f:
            f.write(SHOT_BYTES)
        self.addCleanup(os.remove, self.shot)
        env = patch.dict(os.environ, {"ASC_ISSUER_ID": "iss", "ASC_KEY_ID": "kid", "ASC_KEY_PATH": "/k.p8"})
        env.start()
        self.addCleanup(env.stop)
        tok = patch.object(asc_iap, "token", return_value="test-jwt")
        tok.start()
        self.addCleanup(tok.stop)

    def run_tool(self, routes, *argv):
        fake = FakeASC(routes)
        out = io.StringIO()
        with patch("urllib.request.urlopen", fake), redirect_stdout(out):
            code = asc_iap.main(list(argv))
        return fake, out.getvalue(), code

    def assert_spec_shape(self, path, body):
        rtype, required, allowed, rels = SPEC_CREATE[path]
        data = body["data"]
        self.assertEqual(data["type"], rtype, path)
        attrs = set(data.get("attributes") or {})
        self.assertLessEqual(required, attrs, path)
        self.assertLessEqual(attrs, allowed, path)
        self.assertEqual(set(data["relationships"]), set(rels), path)
        for name, related in rels.items():
            linkage = data["relationships"][name]["data"]
            for item in linkage if isinstance(linkage, list) else [linkage]:
                self.assertEqual(item["type"], related, f"{path} {name}")
                self.assertTrue(item["id"], f"{path} {name}")

    def test_create_on_fresh_app_issues_full_sequence(self):
        fake, out, code = self.run_tool(_fresh_routes(), "create", "--screenshot", self.shot)
        self.assertEqual(code, 0)
        self.assertEqual(fake.calls(), [
            ("GET", APPS_LIST),
            ("POST", "/v2/inAppPurchases"),
            ("GET", LOCS),
            ("POST", "/v1/inAppPurchaseLocalizations"),
            ("GET", SCHEDULE),
            ("GET", POINTS), ("GET", POINTS_2),
            ("POST", "/v1/inAppPurchasePriceSchedules"),
            ("GET", TERRITORIES), ("GET", TERRITORIES_2),
            ("GET", AVAIL),
            ("POST", "/v1/inAppPurchaseAvailabilities"),
            ("GET", SHOT),
            ("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots"),
            ("PUT", UPLOAD_A), ("PUT", UPLOAD_B),
            ("PATCH", "/v1/inAppPurchaseAppStoreReviewScreenshots/S1"),
        ])
        for path in SPEC_CREATE:
            self.assert_spec_shape(path, fake.body("POST", path))

        iap = fake.body("POST", "/v2/inAppPurchases")["data"]
        self.assertEqual(iap["attributes"], {
            "name": "Class Alerts", "productId": "com.salimhafid.UCBShows.classalerts",
            "inAppPurchaseType": "NON_CONSUMABLE", "reviewNote": asc_iap.REVIEW_NOTE, "familySharable": False})
        self.assertEqual(iap["relationships"]["app"]["data"]["id"], "6789625355")

        loc = fake.body("POST", "/v1/inAppPurchaseLocalizations")["data"]
        self.assertEqual(loc["attributes"], {"locale": "en-US", "name": "Class Alerts",
                                             "description": "Alerts when schools post new classes"})
        self.assertEqual(loc["relationships"]["inAppPurchaseV2"]["data"]["id"], IAP)

        sched = fake.body("POST", "/v1/inAppPurchasePriceSchedules")
        rels = sched["data"]["relationships"]
        self.assertEqual(rels["baseTerritory"]["data"]["id"], "USA")
        self.assertEqual(rels["inAppPurchase"]["data"]["id"], IAP)
        [price] = sched["included"]
        self.assertEqual(price["type"], "inAppPurchasePrices")
        self.assertEqual(rels["manualPrices"]["data"], [{"type": "inAppPurchasePrices", "id": price["id"]}])
        self.assertEqual(price["relationships"]["inAppPurchasePricePoint"]["data"],
                         {"type": "inAppPurchasePricePoints", "id": "PP-999"})
        self.assertEqual(price["relationships"]["inAppPurchaseV2"]["data"]["id"], IAP)

        avail = fake.body("POST", "/v1/inAppPurchaseAvailabilities")["data"]
        self.assertIs(avail["attributes"]["availableInNewTerritories"], True)
        self.assertEqual([t["id"] for t in avail["relationships"]["availableTerritories"]["data"]],
                         ["AFG", "USA", "ZWE"])

        reserve = fake.body("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots")["data"]
        self.assertEqual(reserve["attributes"], {"fileName": os.path.basename(self.shot), "fileSize": 10})
        self.assertIn("review screenshot: uploaded", out)

    def test_screenshot_upload_uses_operation_headers_ranges_and_md5(self):
        fake, _, _ = self.run_tool(_fresh_routes(), "create", "--screenshot", self.shot)
        put_a, put_b = [r for r in fake.requests if r.method == "PUT"]
        self.assertEqual(put_a.raw, SHOT_BYTES[:4])
        self.assertEqual(put_b.raw, SHOT_BYTES[4:])
        self.assertEqual(put_a.headers["content-type"], "image/png")
        self.assertEqual(put_a.headers["x-apple-upload-token"], "tok-a")
        self.assertNotIn("authorization", put_a.headers)  # upload URLs are pre-authorized; no JWT
        api_calls = [r for r in fake.requests if r.method != "PUT"]
        self.assertTrue(all(r.headers["authorization"] == "Bearer test-jwt" for r in api_calls))
        commit = fake.body("PATCH", "/v1/inAppPurchaseAppStoreReviewScreenshots/S1")["data"]
        self.assertEqual(commit["type"], "inAppPurchaseAppStoreReviewScreenshots")
        self.assertEqual(commit["id"], "S1")
        self.assertEqual(commit["attributes"], {"uploaded": True,
                                                "sourceFileChecksum": hashlib.md5(SHOT_BYTES).hexdigest()})

    def test_create_when_everything_exists_writes_nothing(self):
        fake, out, code = self.run_tool(_complete_routes(), "create", "--screenshot", self.shot)
        self.assertEqual(code, 0)
        self.assertEqual(fake.writes(), [])
        self.assertNotIn(("GET", POINTS), fake.calls())  # price already right: no price-point lookup
        for line in ("localization en-US: ok", "price: ok (USA 9.99)", "availability: ok (3 territories",
                     "review note: ok", "review screenshot: ok (paywall.png)"):
            self.assertIn(line, out)

    def test_existing_iap_only_patches_what_differs(self):
        routes = _complete_routes(reviewNote="old note")
        routes[("GET", LOCS)]["data"][0]["attributes"]["description"] = "old description"
        routes[("PATCH", f"/v2/inAppPurchases/{IAP}")] = {"data": {"type": "inAppPurchases", "id": IAP}}
        routes[("PATCH", "/v1/inAppPurchaseLocalizations/L1")] = {"data": {"type": "inAppPurchaseLocalizations"}}
        fake, _, _ = self.run_tool(routes, "create", "--screenshot", self.shot)
        self.assertEqual([(r.method, r.path) for r in fake.writes()], [
            ("PATCH", "/v1/inAppPurchaseLocalizations/L1"), ("PATCH", f"/v2/inAppPurchases/{IAP}")])
        self.assertEqual(fake.body("PATCH", f"/v2/inAppPurchases/{IAP}"), {"data": {
            "type": "inAppPurchases", "id": IAP, "attributes": {"reviewNote": asc_iap.REVIEW_NOTE}}})
        self.assertEqual(fake.body("PATCH", "/v1/inAppPurchaseLocalizations/L1")["data"]["attributes"],
                         {"name": "Class Alerts", "description": "Alerts when schools post new classes"})

    def test_failed_screenshot_is_replaced(self):
        routes = _complete_routes()
        routes[("GET", SHOT)]["data"]["attributes"]["assetDeliveryState"]["state"] = "FAILED"
        fresh = _fresh_routes()
        for key in [("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots"), ("PUT", UPLOAD_A), ("PUT", UPLOAD_B),
                    ("PATCH", "/v1/inAppPurchaseAppStoreReviewScreenshots/S1")]:
            routes[key] = fresh[key]
        routes[("DELETE", "/v1/inAppPurchaseAppStoreReviewScreenshots/S0")] = None
        fake, _, _ = self.run_tool(routes, "create", "--screenshot", self.shot)
        self.assertEqual([(r.method, r.path) for r in fake.writes()][:2], [
            ("DELETE", "/v1/inAppPurchaseAppStoreReviewScreenshots/S0"),
            ("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots")])

    def test_price_point_found_on_a_later_page_by_customer_price(self):
        fake = FakeASC(_common_reads())
        with patch("urllib.request.urlopen", fake):
            self.assertEqual(asc_iap.find_price_point(asc_iap.Api(), IAP), "PP-999")
            # 99.9 on page 1 must not match "9.99"; the cursor link is followed to page 2.
            self.assertEqual(fake.calls(), [("GET", POINTS), ("GET", POINTS_2)])
            self.assertIsNone(asc_iap.find_price_point(asc_iap.Api(), IAP, price="12.34"))

    def test_dry_run_on_fresh_app_sends_only_gets(self):
        fake, out, code = self.run_tool(_fresh_routes(), "create", "--screenshot", self.shot, "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(fake.writes(), [])
        # Nothing exists yet, so only the app's IAP list and the territories are read.
        self.assertEqual(fake.calls(), [("GET", APPS_LIST), ("GET", TERRITORIES), ("GET", TERRITORIES_2)])
        for line in ("DRY-RUN POST /v2/inAppPurchases ", "DRY-RUN POST /v1/inAppPurchaseLocalizations ",
                     "DRY-RUN POST /v1/inAppPurchasePriceSchedules ", "DRY-RUN POST /v1/inAppPurchaseAvailabilities ",
                     "DRY-RUN POST /v1/inAppPurchaseAppStoreReviewScreenshots ",
                     "DRY-RUN PATCH /v1/inAppPurchaseAppStoreReviewScreenshots/", "nothing was written"):
            self.assertIn(line, out)
        printed = next(l for l in out.splitlines() if l.startswith("DRY-RUN POST /v2/inAppPurchases "))
        self.assertEqual(json.loads(printed.split(" ", 3)[3])["data"]["attributes"]["productId"], asc_iap.PRODUCT_ID)

    def test_dry_run_on_incomplete_iap_reads_but_never_writes(self):
        routes = _complete_routes(reviewNote="old")
        routes[("GET", SCHEDULE)] = {"data": None}
        routes[("GET", AVAIL)] = NOT_FOUND
        routes[("GET", SHOT)] = NOT_FOUND
        fake, out, _ = self.run_tool(routes, "create", "--screenshot", self.shot, "--dry-run")
        self.assertEqual(fake.writes(), [])
        self.assertIn(("GET", POINTS_2), fake.calls())  # real price point resolved for the printed body
        self.assertIn('"id": "PP-999"', out)
        self.assertIn("review note: would update", out)

    def test_api_error_exits_nonzero_with_apples_text(self):
        routes = _fresh_routes()
        routes[("POST", "/v2/inAppPurchases")] = _error(409, "The provided entity includes an attribute with "
                                                        "a value that has already been used", "productId taken")
        with self.assertRaises(SystemExit) as cm:
            self.run_tool(routes, "create", "--screenshot", self.shot)
        msg = str(cm.exception.code)
        self.assertIn("HTTP 409 POST /v2/inAppPurchases", msg)
        self.assertIn("productId taken", msg)
        self.assertNotEqual(cm.exception.code, 0)

    def test_status_error_and_missing_price_point_exit_nonzero(self):
        with self.assertRaises(SystemExit) as cm:
            self.run_tool({("GET", f"/v1/apps/{asc_iap.APP_ID}/inAppPurchasesV2?limit=200"):
                           _error(401, "Authentication credentials are missing or invalid.", "bad key")}, "status")
        self.assertIn("HTTP 401", str(cm.exception.code))
        routes = _complete_routes()
        routes[("GET", SCHEDULE)] = NOT_FOUND
        routes[("GET", POINTS_2)] = {"data": [_point("PP-1099", "10.99")]}
        with self.assertRaises(SystemExit) as cm:
            self.run_tool(routes, "create", "--screenshot", self.shot)
        self.assertIn("no USA price point at 9.99", str(cm.exception.code))

    def test_missing_credentials_or_screenshot_exit_before_any_request(self):
        with patch.dict(os.environ, {"ASC_KEY_ID": ""}):
            with self.assertRaises(SystemExit) as cm:
                self.run_tool({}, "status")
        self.assertIn("ASC_KEY_ID", str(cm.exception.code))
        with self.assertRaises(SystemExit) as cm:
            self.run_tool({}, "create", "--screenshot", self.shot + ".missing")
        self.assertIn("screenshot not found", str(cm.exception.code))

    def test_status_reports_our_iap(self):
        routes = _complete_routes()
        routes[("GET", f"/v1/apps/{asc_iap.APP_ID}/inAppPurchasesV2?limit=200")] = routes.pop(("GET", APPS_LIST))
        fake, out, code = self.run_tool(routes, "status")
        self.assertEqual(code, 0)
        self.assertEqual(fake.writes(), [])
        for line in ("1 in-app purchase(s)", "state=READY_TO_SUBMIT", 'localization en-US: "Class Alerts"',
                     "manual price: USA 9.99 USD", "availability: 3 territories, availableInNewTerritories=True",
                     "review screenshot: paywall.png state=COMPLETE"):
            self.assertIn(line, out)

    def test_listing_copy_fits_apples_limits(self):
        self.assertLessEqual(len(asc_iap.DISPLAY_NAME), 30)
        self.assertLessEqual(len(asc_iap.DESCRIPTION), 45)
        self.assertLessEqual(len(asc_iap.REVIEW_NOTE), 4000)
        self.assertEqual(asc_iap.PRICE, "9.99")


if __name__ == "__main__":
    unittest.main()

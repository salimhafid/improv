"""Flask app serving the UCB New York shows viewer.

Routes:
  GET  /            polished, filterable HTML page (show data inlined)
  GET  /shows.json  canonical JSON payload — reads the GCS store fresh (no scrape)
  GET  /status      health check (path /healthz is swallowed by an org proxy)
  POST /refresh     re-scrape sources, update GCS + in-memory cache
                    (guarded by the X-Refresh-Token header; called hourly by
                    Cloud Scheduler)

Data flow: scraping happens ONLY on the scheduled POST /refresh, which writes the
GCS store. Reads (GET /shows.json, the app's pull-to-refresh, the web page) serve
the latest from the GCS store so updates show up without triggering a scrape.
"""
from __future__ import annotations

import gzip
import logging
import os
import threading
import time

from flask import Flask, abort, jsonify, render_template, request

import storage
from classes import aggregate_classes
from scraper import filter_payload, scrape

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("ucb.app")

app = Flask(__name__)

REFRESH_TOKEN = os.environ.get("REFRESH_TOKEN", "")

_cache: dict[str, dict | None] = {"payload": None}
_classes_cache: dict[str, dict | None] = {"payload": None}
_lock = threading.Lock()

# Serve the in-memory copy for speed; refresh it from the GCS store at most every
# _FRESH_TTL seconds. Scrapes are throttled per source, so reads stay fast + fresh.
_FRESH_TTL = 60.0
_last_read = {"at": 0.0}
_classes_last_read = {"at": 0.0}


def ensure_loaded() -> dict:
    """Return the cached payload, loading from GCS or scraping if needed."""
    if _cache["payload"] is not None:
        return _cache["payload"]
    with _lock:
        if _cache["payload"] is not None:
            return _cache["payload"]
        payload = storage.load_payload()
        if payload is None:
            log.info("no cached payload available; scraping on demand")
            try:
                payload = scrape()
                storage.save_payload(payload)
            except Exception as e:  # noqa: BLE001 - degrade gracefully
                log.error("on-demand scrape failed: %r", e)
                payload = {"generated_at": None, "source_url": None,
                           "count": 0, "shows": [], "error": str(e)}
        _cache["payload"] = payload
        return payload


def latest_payload() -> dict:
    """Freshest stored payload — no scrape. Serves the in-memory copy and only
    re-reads the GCS store when the copy is older than _FRESH_TTL, so reads are
    fast while still reflecting the hourly scheduled scrape. Falls back to the
    in-memory copy if GCS is briefly unavailable, and only bootstraps a one-time
    scrape on a truly cold start (no GCS object yet)."""
    if _cache["payload"] is not None and (time.monotonic() - _last_read["at"]) < _FRESH_TTL:
        return _cache["payload"]
    payload = storage.load_payload()   # GCS read; None on miss/failure, never scrapes
    if payload is not None:
        _cache["payload"] = payload
        _last_read["at"] = time.monotonic()
        return payload
    if _cache["payload"] is not None:
        return _cache["payload"]
    return ensure_loaded()


def latest_classes() -> dict:
    """Freshest classes payload from the GCS store (no scrape), in-memory TTL."""
    if _classes_cache["payload"] is not None and (time.monotonic() - _classes_last_read["at"]) < _FRESH_TTL:
        return _classes_cache["payload"]
    payload = storage.load_classes()
    if payload is not None:
        _classes_cache["payload"] = payload
        _classes_last_read["at"] = time.monotonic()
        return payload
    if _classes_cache["payload"] is not None:
        return _classes_cache["payload"]
    return {"generated_at": None, "count": 0, "sources": [], "classes": []}


@app.after_request
def _gzip(resp):
    """Compress JSON/HTML responses — the ~340 KB feed shrinks ~6x, which is the
    bulk of the app's startup transfer."""
    accepts = "gzip" in request.headers.get("Accept-Encoding", "")
    ctype = resp.content_type or ""
    if (accepts and resp.status_code == 200 and not resp.direct_passthrough
            and ("application/json" in ctype or "text/html" in ctype)
            and "Content-Encoding" not in resp.headers):
        body = resp.get_data()
        if len(body) > 1024:
            resp.set_data(gzip.compress(body, compresslevel=6))
            resp.headers["Content-Encoding"] = "gzip"
            resp.headers["Content-Length"] = str(len(resp.get_data()))
            resp.headers["Vary"] = "Accept-Encoding"
    return resp


@app.get("/status")
def status():
    # NB: the literal path "/healthz" is intercepted by an org security proxy in
    # the storage-dashboards project, so the health route lives at /status.
    payload = _cache["payload"] or {}
    return {"ok": True, "count": payload.get("count"),
            "generated_at": payload.get("generated_at")}, 200


def _cacheable_json(payload: dict, kind: str):
    """JSON response with an ETag + short max-age. The feed only changes when a
    scheduled scrape stores a new payload, so `generated_at` is a perfect cache
    validator: repeat fetches revalidate with If-None-Match and get an empty 304
    unless there's genuinely new data. Also makes the feeds CDN-cacheable."""
    resp = jsonify(payload)
    resp.set_etag(f"{kind}-{payload.get('generated_at') or 'empty'}")
    resp.headers["Cache-Control"] = "public, max-age=300, stale-while-revalidate=600"
    return resp.make_conditional(request)


@app.get("/shows.json")
def shows_json():
    return _cacheable_json(latest_payload(), "shows")


@app.get("/classes.json")
def classes_json():
    return _cacheable_json(latest_classes(), "classes")


@app.get("/")
def index():
    # The public web page stays UCB New York; the JSON feed carries all sources.
    payload = filter_payload(latest_payload(), {"ucb_ny"})
    return render_template("index.html", payload=payload, hourly=False)


@app.get("/privacy")
def privacy():
    # Static privacy policy for the iOS App Store listing.
    return render_template("privacy.html")


@app.post("/refresh")
def refresh():
    token = request.headers.get("X-Refresh-Token", "")
    if not REFRESH_TOKEN or token != REFRESH_TOKEN:
        abort(403)
    try:
        payload = scrape()
    except Exception as e:  # noqa: BLE001 - keep last-good on failure
        log.error("refresh scrape failed: %r", e)
        kept = (_cache["payload"] or {}).get("generated_at")
        return jsonify({"ok": False, "error": str(e), "kept_generated_at": kept}), 502
    storage.save_payload(payload)
    with _lock:
        _cache["payload"] = payload
        _last_read["at"] = time.monotonic()
    log.info("refreshed: %d shows at %s", payload["count"], payload["generated_at"])

    # Classes (own per-source cadence inside aggregate_classes); isolated so a
    # class failure never fails the shows refresh.
    classes_count = None
    try:
        cpayload = aggregate_classes()
        storage.save_classes(cpayload)
        with _lock:
            _classes_cache["payload"] = cpayload
            _classes_last_read["at"] = time.monotonic()
        classes_count = cpayload["count"]
        log.info("refreshed: %d classes", classes_count)
    except Exception as e:  # noqa: BLE001
        log.error("classes refresh failed: %r", e)

    return jsonify({"ok": True, "count": payload["count"],
                    "generated_at": payload["generated_at"], "classes": classes_count})


if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=int(os.environ.get("PORT", 8080)),
        debug=os.environ.get("FLASK_DEBUG") == "1",
    )

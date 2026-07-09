"""Durable 'last-good' cache for the shows + classes payloads, backed by Google
Cloud Storage. Lets the Cloud Run service serve immediately on cold start and
survive scale-to-zero without re-scraping, and preserves the previous data if a
scrape fails.

If BUCKET is unset (e.g. local dev without GCS), these become no-ops returning
None / False so the app still runs.
"""
from __future__ import annotations

import json
import logging
import os

log = logging.getLogger("ucb.storage")

BUCKET = os.environ.get("BUCKET", "")
SHOWS_BLOB = os.environ.get("BLOB_NAME", "shows.json")
CLASSES_BLOB = os.environ.get("CLASSES_BLOB_NAME", "classes.json")


def _blob(name: str):
    from google.cloud import storage  # imported lazily so local dev needs no creds
    return storage.Client().bucket(BUCKET).blob(name)


def load(name: str) -> dict | None:
    if not BUCKET:
        return None
    try:
        blob = _blob(name)
        if not blob.exists():
            return None
        payload = json.loads(blob.download_as_text())
        log.info("loaded gs://%s/%s (count=%s)", BUCKET, name, payload.get("count"))
        return payload
    except Exception as e:  # noqa: BLE001 - cache is best-effort
        log.warning("GCS load failed for %s: %r", name, e)
        return None


def save(name: str, payload: dict) -> bool:
    if not BUCKET:
        return False
    try:
        blob = _blob(name)
        blob.cache_control = "no-cache"
        blob.upload_from_string(json.dumps(payload, ensure_ascii=False), content_type="application/json")
        log.info("saved gs://%s/%s (count=%s)", BUCKET, name, payload.get("count"))
        return True
    except Exception as e:  # noqa: BLE001 - cache is best-effort
        log.warning("GCS save failed for %s: %r", name, e)
        return False


def load_payload() -> dict | None:
    return load(SHOWS_BLOB)


def save_payload(payload: dict) -> bool:
    return save(SHOWS_BLOB, payload)


def load_classes() -> dict | None:
    return load(CLASSES_BLOB)


def save_classes(payload: dict) -> bool:
    return save(CLASSES_BLOB, payload)

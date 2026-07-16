"""Durable 'last-good' cache for the shows + classes payloads.

Two backends, picked by environment:
  - LOCAL_STORE_DIR: plain JSON files in a directory. Used by the GitHub
    Actions publisher, where the checked-out repo's docs/ folder is both the
    previous-payload cache (so per-source scrape cadences carry across runs)
    and the content GitHub Pages serves.
  - BUCKET: Google Cloud Storage (the legacy Cloud Run deployment).

If neither is set (e.g. bare local dev), these are no-ops returning None/False
so the app still runs.
"""
from __future__ import annotations

import json
import logging
import os

log = logging.getLogger("ucb.storage")

LOCAL_DIR = os.environ.get("LOCAL_STORE_DIR", "")
BUCKET = os.environ.get("BUCKET", "")
SHOWS_BLOB = os.environ.get("BLOB_NAME", "shows.json")
CLASSES_BLOB = os.environ.get("CLASSES_BLOB_NAME", "classes.json")
TALENT_BLOB = os.environ.get("TALENT_BLOB_NAME", "talent.json")


def _blob(name: str):
    from google.cloud import storage  # imported lazily so local dev needs no creds
    return storage.Client().bucket(BUCKET).blob(name)


def load(name: str) -> dict | None:
    if LOCAL_DIR:
        path = os.path.join(LOCAL_DIR, name)
        try:
            with open(path, encoding="utf-8") as f:
                payload = json.load(f)
            log.info("loaded %s (count=%s)", path, payload.get("count"))
            return payload
        except FileNotFoundError:
            return None
        except Exception as e:  # noqa: BLE001 - cache is best-effort
            log.warning("local load failed for %s: %r", path, e)
            return None
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
    if LOCAL_DIR:
        path = os.path.join(LOCAL_DIR, name)
        try:
            os.makedirs(LOCAL_DIR, exist_ok=True)
            tmp = f"{path}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)
            os.replace(tmp, path)
            log.info("saved %s (count=%s)", path, payload.get("count"))
            return True
        except Exception as e:  # noqa: BLE001 - cache is best-effort
            log.warning("local save failed for %s: %r", path, e)
            return False
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


def load_talent() -> dict | None:
    return load(TALENT_BLOB)


def save_talent(payload: dict) -> bool:
    return save(TALENT_BLOB, payload)

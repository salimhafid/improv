"""Durable 'last-good' cache for the shows / classes / talent payloads.

One backend: LOCAL_STORE_DIR, plain JSON files in a directory. The GitHub
Actions publisher runs with LOCAL_STORE_DIR=docs so the checked-out repo's
docs/ folder is both the previous-payload cache (per-source scrape cadences
carry across runs) and the content the raw CDN serves. With LOCAL_STORE_DIR
unset (bare local dev), loads return None and saves return False so
everything still runs statelessly.

(The Google Cloud Storage backend from the Cloud Run era was removed
2026-07-22 along with the rest of that stack.)
"""
from __future__ import annotations

import json
import logging
import os

log = logging.getLogger("ucb.storage")

LOCAL_DIR = os.environ.get("LOCAL_STORE_DIR", "")
SHOWS_BLOB = "shows.json"
CLASSES_BLOB = "classes.json"
TALENT_BLOB = "talent.json"


def load(name: str) -> dict | None:
    if not LOCAL_DIR:
        return None
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


def save(name: str, payload: dict) -> bool:
    if not LOCAL_DIR:
        return False
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

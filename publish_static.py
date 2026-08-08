"""Scrape shows + classes and publish them as static JSON for GitHub Pages.

Run with LOCAL_STORE_DIR=docs so the checked-out docs/ folder is both the
previous-payload cache (per-source scrape cadences carry across runs — sources
not yet due keep their last-good data) and the content Pages serves.

Usage (as in .github/workflows/scrape.yml):
    LOCAL_STORE_DIR=docs python publish_static.py

Exits nonzero only if *every* show source failed — a partial failure keeps the
last-good data for the failing sources and still publishes. An empty classes
or talent payload with no successful source is skipped (the previous file
stays in place) rather than blanking that feed.
"""
from __future__ import annotations

import logging
import sys

import storage
from classes import aggregate_classes
from scraper import scrape
from talent import aggregate_talent


def _save_guarded(name: str, payload: dict, items_key: str, save_fn) -> None:
    """Refuse to overwrite a feed with emptiness: zero items AND zero healthy
    sources can only mean total scrape failure (or corrupt previous state), so
    keep the last-published file instead."""
    items = payload.get(items_key) or []
    any_ok = any(s.get("ok") for s in payload.get("sources", []))
    if not items and not any_ok:
        print(f"{name}: 0 items and no source succeeded — keeping the previous file",
              file=sys.stderr)
        return
    save_fn(payload)


def main() -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)

    payload = scrape()
    classes_payload = aggregate_classes()
    talent_payload = aggregate_talent()

    print(f"shows: {payload.get('count')} · classes: {classes_payload.get('count')}"
          f" · talent: {talent_payload.get('count')}")
    ok = []
    for s in payload.get("sources", []):
        if s.get("ok"):
            ok.append(s.get("id"))
        status = "ok" if s.get("ok") else f"FAILED: {s.get('error')}"
        stale = " (stale carry-over)" if s.get("stale") else ""
        print(f"  {s.get('id')}: {s.get('count')} {status}{stale}")

    if not ok:
        print("every show source failed — refusing to publish an empty feed", file=sys.stderr)
        return 1

    storage.save_payload(payload)
    _save_guarded("classes", classes_payload, "classes", storage.save_classes)
    _save_guarded("talent", talent_payload, "people", storage.save_talent)
    return 0


if __name__ == "__main__":
    sys.exit(main())

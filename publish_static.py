"""Scrape shows + classes and publish them as static JSON for GitHub Pages.

Run with LOCAL_STORE_DIR=docs so the checked-out docs/ folder is both the
previous-payload cache (per-source scrape cadences carry across runs — sources
not yet due keep their last-good data) and the content Pages serves.

Usage (as in .github/workflows/scrape.yml):
    LOCAL_STORE_DIR=docs python publish_static.py

Exits nonzero only if *every* show source failed — a partial failure keeps the
last-good data for the failing sources and still publishes.
"""
from __future__ import annotations

import logging
import sys

import storage
from classes import aggregate_classes
from scraper import scrape


def main() -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)

    payload = scrape()
    storage.save_payload(payload)
    classes_payload = aggregate_classes()
    storage.save_classes(classes_payload)

    print(f"shows: {payload.get('count')} · classes: {classes_payload.get('count')}")
    ok, failed = [], []
    for s in payload.get("sources", []):
        (ok if s.get("ok") else failed).append(s.get("id"))
        status = "ok" if s.get("ok") else f"FAILED: {s.get('error')}"
        stale = " (stale carry-over)" if s.get("stale") else ""
        print(f"  {s.get('id')}: {s.get('count')} {status}{stale}")

    if not ok:
        print("every show source failed — refusing to publish an empty feed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

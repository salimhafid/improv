"""Scrape shows, classes and talent and publish them as static JSON in docs/,
which the app reads from GitHub's raw CDN (raw.githubusercontent.com).

Run with LOCAL_STORE_DIR=docs so the checked-out docs/ folder is both the
previous-payload cache (per-source scrape cadences carry across runs — sources
not yet due keep their last-good data) and the content the raw CDN serves.

Usage (as in .github/workflows/scrape.yml):
    LOCAL_STORE_DIR=docs python publish_static.py

Exits nonzero if no show source contributed any shows (a partial failure keeps
the last-good data for the failing sources and still publishes), or if any feed
could not be written to the store. A classes or talent payload to which no
source contributed items is skipped (the previous file stays in place) rather
than blanking that feed.
"""
from __future__ import annotations

import logging
import sys

import storage
from classes import aggregate_classes
from scraper import scrape
from talent import aggregate_talent


def _healthy(source: dict) -> bool:
    """A source vouches for a feed only when it contributed items. `ok` alone
    is not enough: a legitimately empty scrape (wgis_ny answers with zero
    shows every run) is ok=True/count=0 and must not let an otherwise-empty
    payload — every other source failed with nothing to carry — overwrite the
    last-good file."""
    return bool(source.get("ok")) and (source.get("count") or 0) > 0


def _save_guarded(name: str, payload: dict, save_fn) -> bool:
    """Refuse to overwrite a feed with emptiness: no source contributing items
    can only mean total scrape failure (or corrupt previous state), so keep
    the last-published file instead. Returns False only when the write itself
    failed."""
    if not any(_healthy(s) for s in payload.get("sources", [])):
        print(f"{name}: no source contributed items — keeping the previous file",
              file=sys.stderr)
        return True
    return save_fn(payload)


def main() -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)

    payload = scrape()
    classes_payload = aggregate_classes()
    talent_payload = aggregate_talent()

    print(f"shows: {payload.get('count')} · classes: {classes_payload.get('count')}"
          f" · talent: {talent_payload.get('count')}")
    healthy = []
    for s in payload.get("sources", []):
        if _healthy(s):
            healthy.append(s.get("id"))
        status = "ok" if s.get("ok") else f"FAILED: {s.get('error')}"
        stale = " (stale carry-over)" if s.get("stale") else ""
        print(f"  {s.get('id')}: {s.get('count')} {status}{stale}")

    if not healthy:
        print("no show source contributed shows — refusing to publish an empty feed",
              file=sys.stderr)
        return 1

    # A failed write (unserialisable value, disk error, LOCAL_STORE_DIR unset)
    # is logged by storage and returned as False; it must fail the run rather
    # than leave the old feed in place behind a green build.
    saved = {"shows": storage.save_payload(payload),
             "classes": _save_guarded("classes", classes_payload, storage.save_classes),
             "talent": _save_guarded("talent", talent_payload, storage.save_talent)}
    failed = [name for name, ok in saved.items() if not ok]
    if failed:
        print(f"could not write {', '.join(failed)} to the store (is LOCAL_STORE_DIR set?)",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

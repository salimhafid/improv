"""Classes aggregator.

Mirrors scraper.aggregate() for the class data type: runs each adapter daily
(the heaviest source is Magnet at ~15 requests/run, and a 24h cadence keeps
freshly announced sections and sold-out states at most a day stale), carries
over last-good data for sources not due or that fail, and filters to upcoming
(start >= today, undated kept).
"""
from __future__ import annotations

import json
import logging
import sys
from datetime import date, datetime, timezone

from dateutil import parser as dateparser

import storage
from aggregation import run_sources
from sources import CLASS_SOURCES

log = logging.getLogger("ucb.classes")

_CLASS_INTERVALS: dict[str, int] = {}     # per-source overrides, none currently
_DEFAULT_CLASS_INTERVAL = 24 * 3600       # daily for every class source
_GRACE = 30 * 60


def _is_upcoming(item: dict, today: date) -> bool:
    ref = item.get("start")
    if not ref:
        return True  # undated classes (e.g. drop-ins) always shown
    try:
        return dateparser.parse(ref).date() >= today
    except (ValueError, OverflowError, TypeError):
        return True


def aggregate_classes(now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)

    previous = storage.load_classes() or {}
    prev_by_source: dict[str, list[dict]] = {}
    for c in previous.get("classes", []):
        prev_by_source.setdefault(c.get("source"), []).append(c)
    prev_scraped = {s.get("id"): s.get("scraped_at") for s in previous.get("sources", [])}

    all_classes, summary = run_sources(
        CLASS_SOURCES, previous_items=prev_by_source, prev_scraped=prev_scraped,
        now=now, intervals=_CLASS_INTERVALS,
        default_interval=_DEFAULT_CLASS_INTERVAL, grace=_GRACE,
        keep=_is_upcoming, log=log, label="class source",
    )
    all_classes.sort(key=lambda c: (c.get("start") or "9999-12-31", c.get("title", "")))
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "count": len(all_classes),
        "sources": summary,
        "classes": all_classes,
    }


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    print(json.dumps(aggregate_classes(), indent=2, ensure_ascii=False))

"""Classes aggregator.

Mirrors scraper.aggregate() for the class data type: runs each adapter in
CLASS_SOURCES only when due per its cadence (UCB NY + WGIS every 24h, others
every 7 days), carries over last-good data for sources not due or that fail, and
filters to upcoming (start >= today, undated kept).
"""
from __future__ import annotations

import json
import logging
import sys
from datetime import date, datetime, timezone

from dateutil import parser as dateparser

import storage
from sources import CLASS_SOURCES

log = logging.getLogger("ucb.classes")

_CLASS_INTERVALS = {"ucb_ny": 24 * 3600, "wgis_ny": 24 * 3600, "wgis_la": 24 * 3600}
_DEFAULT_CLASS_INTERVAL = 7 * 24 * 3600   # other theaters: weekly
_GRACE = 30 * 60


def _is_upcoming(item: dict, today: date) -> bool:
    ref = item.get("start")
    if not ref:
        return True  # undated classes (e.g. drop-ins) always shown
    try:
        return dateparser.parse(ref).date() >= today
    except (ValueError, OverflowError, TypeError):
        return True


def _parse_dt(value):
    if not value:
        return None
    try:
        d = dateparser.parse(value)
        return d.replace(tzinfo=timezone.utc) if d.tzinfo is None else d
    except (ValueError, OverflowError, TypeError):
        return None


def aggregate_classes(today: date | None = None, now: datetime | None = None) -> dict:
    today = today or date.today()
    now = now or datetime.now(timezone.utc)

    previous = storage.load_classes() or {}
    prev_by_source: dict[str, list[dict]] = {}
    for c in previous.get("classes", []):
        prev_by_source.setdefault(c.get("source"), []).append(c)
    prev_scraped = {s.get("id"): s.get("scraped_at") for s in previous.get("sources", [])}

    all_classes: list[dict] = []
    summary: list[dict] = []

    for src in CLASS_SOURCES:
        sid, org, city = src["id"], src["org"], src["city"]
        interval = _CLASS_INTERVALS.get(sid, _DEFAULT_CLASS_INTERVAL)
        last = _parse_dt(prev_scraped.get(sid))
        due = last is None or (now - last).total_seconds() >= (interval - _GRACE)
        carried = [c for c in prev_by_source.get(sid, []) if _is_upcoming(c, today)]

        if not due:
            all_classes.extend(carried)
            summary.append({"id": sid, "org": org, "city": city, "count": len(carried),
                            "ok": True, "stale": False, "scraped_at": prev_scraped.get(sid), "error": None})
            log.info("class source %s: not due (cadence), carried %d", sid, len(carried))
            continue

        try:
            items = src["fetch"]() or []
            for c in items:
                c.setdefault("source", sid)
                c.setdefault("org", org)
                c.setdefault("city", city)
            upcoming = [c for c in items if _is_upcoming(c, today)]
            all_classes.extend(upcoming)
            summary.append({"id": sid, "org": org, "city": city, "count": len(upcoming),
                            "ok": True, "stale": False, "scraped_at": now.isoformat(), "error": None})
            log.info("class source %s: scraped %d", sid, len(upcoming))
        except Exception as e:  # noqa: BLE001
            all_classes.extend(carried)
            summary.append({"id": sid, "org": org, "city": city, "count": len(carried),
                            "ok": bool(carried), "stale": bool(carried),
                            "scraped_at": prev_scraped.get(sid), "error": str(e)})
            log.warning("class source %s failed: %r (carried %d)", sid, e, len(carried))

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

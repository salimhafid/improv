"""Classes aggregator.

Mirrors scraper.aggregate() for the class data type: runs each adapter daily
(the heaviest source is Magnet at ~15 requests/run, and a 24h cadence keeps
freshly announced sections and sold-out states at most a day stale), carries
over last-good data for sources not due or that fail, and filters to upcoming
(start >= today, undated kept).

The one exception to the daily cadence: when the class-alert watcher
(watcher.py) has detected new classes at a school since that source was last
scraped, the source is forced due. The watcher pushes "new class" alerts
within minutes, and a push for a class the Classes tab can't show for up to a
day is the bug this closes. The signal is the per-school "new_at" stamp in the
watcher's state (class-watch.json), passed in as `watch_state`; watcher school
ids are the class source ids.
"""
from __future__ import annotations

import json
import logging
import sys
from datetime import date, datetime, timezone

from dateutil import parser as dateparser

import storage
from aggregation import parse_dt, run_sources
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


def _forced_by_watcher(watch_state, prev_scraped: dict) -> set[str]:
    """Class source ids the watcher has seen new classes at since their last
    scrape: "new_at" later than the previous payload's scraped_at, or no
    previous scraped_at at all.

    The comparison is against the durable stamps rather than "a dispatch
    asked for it", so any publish run (the watcher's dispatched classes-only
    run, or the hourly cron if GitHub replaced that pending run) forces the
    same sources, and a run whose fetch failed (scraped_at unchanged) leaves
    the source forced for the next one. Once a scrape lands, scraped_at moves
    past new_at and the source returns to its daily cadence.

    The state is another job's file, so anything malformed (a non-dict state
    or entry, an unparseable stamp) is ignored rather than allowed to break
    the publish; only ids that are actual class sources are considered.
    """
    if not isinstance(watch_state, dict):
        return set()
    forced: set[str] = set()
    for src in CLASS_SOURCES:
        sid = src["id"]
        entry = watch_state.get(sid)
        if not isinstance(entry, dict):
            continue
        new_at = parse_dt(entry.get("new_at"))
        if new_at is None:
            continue
        last = parse_dt(prev_scraped.get(sid))
        if last is None or new_at > last:
            forced.add(sid)
    return forced


def aggregate_classes(now: datetime | None = None, *, watch_state: dict | None = None) -> dict:
    """Build the classes payload. `watch_state` is the class watcher's parsed
    class-watch.json (or None): sources with newer detections than their
    last scrape are forced due this run (see _forced_by_watcher)."""
    now = now or datetime.now(timezone.utc)

    previous = storage.load_classes() or {}
    prev_by_source: dict[str, list[dict]] = {}
    for c in previous.get("classes", []):
        if isinstance(c, dict):    # a corrupt previous row is dropped, not fatal
            prev_by_source.setdefault(c.get("source"), []).append(c)
    prev_scraped = {s.get("id"): s.get("scraped_at") for s in previous.get("sources", [])}

    # Interval 0 makes a source due regardless of its last stamp, without
    # run_sources' force=True (which would refetch every source).
    forced = _forced_by_watcher(watch_state, prev_scraped)
    if forced:
        log.info("class sources forced due by new-class detections: %s",
                 ", ".join(sorted(forced)))

    all_classes, summary = run_sources(
        CLASS_SOURCES, previous_items=prev_by_source, prev_scraped=prev_scraped,
        now=now, intervals={**_CLASS_INTERVALS, **{sid: 0 for sid in forced}},
        default_interval=_DEFAULT_CLASS_INTERVAL, grace=_GRACE,
        keep=_is_upcoming, log=log, label="class source",
    )
    # `or ""` (not a .get default): a present-but-null title would otherwise
    # make the tie-break compare None with str and abort the run.
    all_classes.sort(key=lambda c: (c.get("start") or "9999-12-31", c.get("title") or ""))
    return {
        "generated_at": now.isoformat(),
        "count": len(all_classes),
        "sources": summary,
        "classes": all_classes,
    }


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    print(json.dumps(aggregate_classes(), indent=2, ensure_ascii=False))

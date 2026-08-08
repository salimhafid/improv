"""The shared per-source cadence/carry loop behind both feed aggregators.

scraper.py (shows) and classes.py (classes) used to hand-roll identical loops;
they now both call run_sources(). The contract, unchanged from the originals:

  - A source is scraped only when due per its interval (with a grace window so
    a slightly-early scheduler tick still counts). Sources not due carry their
    previous items forward, filtered by `keep`.
  - A scrape failure carries the previous items too, flagged stale — a
    transient block never wipes a source from the feed.
  - Every source gets a summary row (id/org/city/count/ok/stale/scraped_at/
    error) so probe runs can distinguish "scraped N" from "carried".
"""
from __future__ import annotations

import logging
from datetime import date, datetime, timezone
from typing import Callable

from dateutil import parser as dateparser

from common import local_today


def parse_dt(value) -> datetime | None:
    """Parse a stored scraped_at timestamp; naive values are assumed UTC."""
    if not value:
        return None
    try:
        d = dateparser.parse(value)
        return d.replace(tzinfo=timezone.utc) if d.tzinfo is None else d
    except (ValueError, OverflowError, TypeError):
        return None


def run_sources(
    sources: list[dict],
    *,
    previous_items: dict[str, list[dict]],
    prev_scraped: dict[str, str | None],
    now: datetime,
    intervals: dict[str, int],
    default_interval: int,
    grace: int,
    keep: Callable[[dict, date], bool],
    on_scraped: Callable[[dict, list[dict]], None] | None = None,
    log: logging.Logger | None = None,
    label: str = "source",
) -> tuple[list[dict], list[dict]]:
    """Run each source when due, carrying previous items otherwise.

    previous_items maps source id -> that source's items from the last payload.
    keep(item, today) filters both fresh and carried items to what's upcoming;
    `today` is reckoned in each source's OWN city timezone (a UTC today on the
    runner would drop the current night's shows from evening builds).
    on_scraped(src, items) runs after a successful scrape (e.g. detail
    enrichment) — its cost counts toward that source's try/except.
    Returns (all_items, summary).
    """
    log = log or logging.getLogger("ucb.aggregation")
    all_items: list[dict] = []
    summary: list[dict] = []

    for src in sources:
        sid, org, city = src["id"], src["org"], src["city"]
        today = local_today(city, now)
        interval = intervals.get(sid, default_interval)
        last = parse_dt(prev_scraped.get(sid))
        due = last is None or (now - last).total_seconds() >= (interval - grace)
        carried = [x for x in previous_items.get(sid, []) if keep(x, today)]

        def carry(*, stale: bool, error: str | None) -> None:
            all_items.extend(carried)
            summary.append({"id": sid, "org": org, "city": city, "count": len(carried),
                            "ok": True if not stale else bool(carried), "stale": stale and bool(carried),
                            "scraped_at": prev_scraped.get(sid), "error": error})

        if not due:
            carry(stale=False, error=None)
            log.info("%s %s: not due (cadence), carried %d", label, sid, len(carried))
            continue

        try:
            items = src["fetch"]() or []
            for x in items:  # defensive: ensure every item is tagged
                x.setdefault("source", sid)
                x.setdefault("org", org)
                x.setdefault("city", city)
            fresh = [x for x in items if keep(x, today)]
            if not fresh and carried:
                # A 200-OK page that parses to zero items is indistinguishable
                # from a silent markup change; keep last-good data (flagged
                # stale, scraped_at unchanged so the next run retries) instead
                # of wiping the source. Legitimately empty sources have no
                # carry and still publish empty.
                carry(stale=True, error="scraped 0 items; kept last-good data")
                log.warning("%s %s: scraped 0 items, carried %d (possible markup change)",
                            label, sid, len(carried))
                continue
            if on_scraped:
                on_scraped(src, fresh)
            all_items.extend(fresh)
            summary.append({"id": sid, "org": org, "city": city, "count": len(fresh),
                            "ok": True, "stale": False,
                            "scraped_at": now.isoformat(), "error": None})
            log.info("%s %s: scraped %d", label, sid, len(fresh))
        except Exception as e:  # noqa: BLE001 - one bad source must not break the feed
            carry(stale=True, error=str(e))
            log.warning("%s %s failed: %r (carried %d)", label, sid, e, len(carried))

    return all_items, summary

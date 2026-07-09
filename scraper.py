"""Multi-source show aggregator.

Runs every venue adapter in `sources/`, merges their normalized show dicts into a
single payload (each show tagged with source/org/city), filters to upcoming, and
sorts chronologically. A per-source failure is captured in the `sources` summary
(ok=false) and never breaks the feed.

Runnable standalone (`python scraper.py` prints the JSON payload) and importable
by the Flask app and the local-site builder.
"""
from __future__ import annotations

import json
import logging
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone

from dateutil import parser as dateparser

import storage
from sources import SOURCES

log = logging.getLogger("ucb.scraper")

SOURCE_URL = "https://ucbcomedy.com/shows/new-york/"

# Detail-page enrichment: reuse cached details for known shows, fetch only new
# ones, capped per run (parallelized) so a scrape stays bounded.
_DETAIL_BUDGET = 400
_DETAIL_WORKERS = 8

# Per-source scrape cadence: scrape a source at most this often (the scheduler
# may fire more frequently; sources not yet due are carried over from the store).
_SCRAPE_INTERVALS = {"ucb_ny": 3 * 3600}      # UCB New York: every 3h
_DEFAULT_SCRAPE_INTERVAL = 24 * 3600          # everything else: every 24h
_SCRAPE_GRACE = 30 * 60                        # let a scheduled tick fire slightly early


def _is_upcoming(show: dict, today: date) -> bool:
    ref = show.get("end") or show.get("start")
    if not ref:
        return True
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


def _enrich_details(shows, detail_fn, prev_detail, budget) -> int:
    """Fill description/cast: reuse cached details by url for shows already
    attempted in a prior run, fetch (in parallel, up to `budget`) only shows not
    yet attempted. Each processed show is flagged `detail_done` so a page that
    legitimately has no description/cast (or a transient fetch failure) is not
    re-fetched on every run — the cache converges. Returns the number fetched."""
    def safe(url):
        try:
            return detail_fn(url)
        except Exception:  # noqa: BLE001
            return "", ""
    to_fetch = []
    for show in shows:
        cached = prev_detail.get(show.get("url"))
        if cached is not None:
            show["description"], show["cast"] = cached  # reuse even if empty
            show["detail_done"] = True
        elif show.get("url"):
            to_fetch.append(show)
    to_fetch = to_fetch[:max(0, budget)]
    if to_fetch:
        with ThreadPoolExecutor(max_workers=_DETAIL_WORKERS) as ex:
            results = list(ex.map(lambda s: safe(s["url"]), to_fetch))
        for s, (desc, cast) in zip(to_fetch, results):
            if desc:
                s["description"] = desc
            if cast:
                s["cast"] = cast
            s["detail_done"] = True   # attempted; don't re-fetch next run
    return len(to_fetch)


def aggregate(today: date | None = None, now: datetime | None = None) -> dict:
    """Build the payload, scraping each source only when it's due per its cadence.

    Sources not due, or that fail, carry over their last-good shows from the
    previous payload — so we honor the 24h/6h cadence and a transient failure
    (e.g. a Cloudflare blip on UCB) never wipes a source from the feed.
    """
    today = today or date.today()
    now = now or datetime.now(timezone.utc)

    previous = storage.load_payload() or {}
    prev_by_source: dict[str, list[dict]] = {}
    for s in previous.get("shows", []):
        prev_by_source.setdefault(s.get("source"), []).append(s)
    prev_scraped = {s.get("id"): s.get("scraped_at") for s in previous.get("sources", [])}
    # Per-show detail cache (by url) carried from the previous payload. A show
    # counts as already-attempted if it was flagged detail_done OR already has a
    # description/cast (covers payloads written before detail_done existed), so we
    # neither re-fetch description-less pages forever nor drop cast-only results.
    prev_detail = {s.get("url"): (s.get("description", ""), s.get("cast", ""))
                   for s in previous.get("shows", [])
                   if s.get("url") and (s.get("detail_done") or s.get("description") or s.get("cast"))}
    detail_budget = _DETAIL_BUDGET

    all_shows: list[dict] = []
    summary: list[dict] = []

    for src in SOURCES:
        sid, org, city = src["id"], src["org"], src["city"]
        interval = _SCRAPE_INTERVALS.get(sid, _DEFAULT_SCRAPE_INTERVAL)
        last = _parse_dt(prev_scraped.get(sid))
        due = last is None or (now - last).total_seconds() >= (interval - _SCRAPE_GRACE)
        carried = [s for s in prev_by_source.get(sid, []) if _is_upcoming(s, today)]

        if not due:
            all_shows.extend(carried)
            summary.append({"id": sid, "org": org, "city": city, "count": len(carried),
                            "ok": True, "stale": False,
                            "scraped_at": prev_scraped.get(sid), "error": None})
            log.info("source %s: not due (cadence), carried %d", sid, len(carried))
            continue

        try:
            shows = src["fetch"]() or []
            for s in shows:  # defensive: ensure every show is tagged
                s.setdefault("source", sid)
                s.setdefault("org", org)
                s.setdefault("city", city)
            upcoming = [s for s in shows if _is_upcoming(s, today)]
            if src.get("detail"):
                fetched = _enrich_details(upcoming, src["detail"], prev_detail, detail_budget)
                detail_budget -= fetched
            all_shows.extend(upcoming)
            summary.append({"id": sid, "org": org, "city": city, "count": len(upcoming),
                            "ok": True, "stale": False,
                            "scraped_at": now.isoformat(), "error": None})
            log.info("source %s: scraped %d upcoming", sid, len(upcoming))
        except Exception as e:  # noqa: BLE001 - one bad source must not break the feed
            all_shows.extend(carried)
            summary.append({"id": sid, "org": org, "city": city, "count": len(carried),
                            "ok": bool(carried), "stale": bool(carried),
                            "scraped_at": prev_scraped.get(sid), "error": str(e)})
            log.warning("source %s failed: %r (carried %d stale shows)", sid, e, len(carried))

    all_shows.sort(key=lambda s: (s.get("start") or s.get("end") or "9999-12-31"))
    return build_payload(all_shows, summary)


def build_payload(shows: list[dict], sources: list[dict] | None = None) -> dict:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_url": SOURCE_URL,
        "count": len(shows),
        "sources": sources or [],
        "shows": shows,
    }


def filter_payload(payload: dict, source_ids: set[str]) -> dict:
    """Subset a payload to specific source ids (old cache entries with no source
    are treated as ucb_ny). Used to keep the web/local pages UCB-NY only."""
    shows = [
        s for s in payload.get("shows", [])
        if s.get("source") in source_ids or (not s.get("source") and "ucb_ny" in source_ids)
    ]
    return {**payload, "count": len(shows), "shows": shows}


def scrape() -> dict:
    return aggregate()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    print(json.dumps(scrape(), indent=2, ensure_ascii=False))

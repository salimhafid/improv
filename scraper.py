"""Multi-source show aggregator.

Runs every venue adapter in `sources/`, merges their normalized show dicts into a
single payload (each show tagged with source/org/city), filters to upcoming, and
sorts chronologically. A per-source failure is captured in the `sources` summary
(ok=false) and never breaks the feed.

Runnable standalone (`python scraper.py` prints the JSON payload) and importable
by publish_static.py, which writes it to the static store.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone

from dateutil import parser as dateparser

import storage
from aggregation import run_sources
from sources import SOURCES

log = logging.getLogger("ucb.scraper")

# Detail-page enrichment: reuse cached details for known shows, fetch only new
# ones, capped per run (parallelized) so a scrape stays bounded.
_DETAIL_BUDGET = 400
_DETAIL_WORKERS = 8
# The budget bounds requests, not time: a host that hangs instead of erroring
# costs ~100 s per URL (3 attempts x 30 s + backoff), so 400 URLs / 8 workers
# could outlive scrape.yml's 20-minute job timeout. Once this many seconds
# have passed since aggregate() started, no NEW detail fetch is begun; the
# rest stay unflagged (no detail_done) and are picked up next run.
_DETAIL_DEADLINE = 8 * 60
_PAST_DEADLINE = object()    # safe() result for a fetch skipped by the deadline

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


def _excerpt(text: str, limit: int = 240) -> str:
    """First `limit` characters of a description, cut at a word boundary."""
    text = text.strip()
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0].rstrip(",;:—-")
    return (cut or text[:limit]) + "…"


def _enrich_details(shows, detail_fn, prev_detail, budget, deadline=None) -> int:
    """Fill description/cast/hero image: reuse cached details by url for shows
    already fetched in a prior run; fetch each *unique* uncached url once (in
    parallel, up to `budget` — per-occurrence sources like Magnet share one
    page across many calendar dates). The detail page's og:image only fills in
    when the listing gave no artwork. Successful fetches are flagged
    `detail_done` so pages that legitimately have no description/cast still
    converge; a FAILED fetch (detail_fn returns None) is left unflagged so the
    next run retries instead of caching emptiness forever. `deadline` is a
    time.monotonic() instant after which no new fetch is started (those are
    left unflagged too). Returns the number of unique pages attempted."""
    def safe(url):
        if deadline is not None and time.monotonic() >= deadline:
            return _PAST_DEADLINE
        try:
            return detail_fn(url)
        except Exception:  # noqa: BLE001
            return None    # failure — retry next run

    def apply(show, desc, cast, img, members):
        if desc:
            show["description"] = desc
            # Sources whose listing carries no blurb (Magnet's calendar) get
            # their excerpt from the detail copy: the app searches and writes
            # calendar notes from `excerpt`, not `description`.
            if not show.get("excerpt"):
                show["excerpt"] = _excerpt(desc)
        if cast:
            show["cast"] = cast
        if img and not show.get("image"):
            show["image"] = img
        if members:
            show["cast_members"] = members
        show["detail_done"] = True

    urls_to_fetch: list[str] = []
    pending: dict[str, list[dict]] = {}
    for show in shows:
        url = show.get("url")
        if not url:
            continue
        cached = prev_detail.get(url)
        if cached is not None:
            apply(show, *cached)  # reuse even if empty — it was fetched OK once
        else:
            if url not in pending:
                urls_to_fetch.append(url)
            pending.setdefault(url, []).append(show)

    urls_to_fetch = urls_to_fetch[:max(0, budget)]
    if urls_to_fetch:
        with ThreadPoolExecutor(max_workers=_DETAIL_WORKERS) as ex:
            results = list(ex.map(safe, urls_to_fetch))
        skipped = sum(1 for r in results if r is _PAST_DEADLINE)
        if skipped:
            log.warning("detail deadline reached: %d page(s) left for the next run", skipped)
        for url, result in zip(urls_to_fetch, results):
            if result is None or result is _PAST_DEADLINE:
                continue           # transient failure / out of time: no detail_done, retried next run
            prev_detail[url] = result  # in-run cache for later sources/occurrences
            for show in pending[url]:
                apply(show, *result)
        return len(urls_to_fetch) - skipped
    return 0


def aggregate(now: datetime | None = None) -> dict:
    """Build the payload, scraping each source only when it's due per its cadence.

    Sources not due, or that fail (or suspiciously scrape zero items), carry
    over their last-good shows from the previous payload — so we honor the
    cadence and a transient failure (e.g. a Cloudflare blip on UCB) never
    wipes a source from the feed. Upcoming-ness is judged against each
    source's own city-local today.
    """
    now = now or datetime.now(timezone.utc)

    previous = storage.load_payload() or {}
    prev_by_source: dict[str, list[dict]] = {}
    for s in previous.get("shows", []):
        if isinstance(s, dict):    # a corrupt previous row is dropped, not fatal
            prev_by_source.setdefault(s.get("source"), []).append(s)
    prev_scraped = {s.get("id"): s.get("scraped_at") for s in previous.get("sources", [])}
    # Per-show detail cache (by url) carried from the previous payload. A show
    # counts as already-attempted if it was flagged detail_done OR already has a
    # description/cast (covers payloads written before detail_done existed), so we
    # neither re-fetch description-less pages forever nor drop cast-only results.
    prev_detail = {s.get("url"): (s.get("description", ""), s.get("cast", ""), s.get("image"),
                                  s.get("cast_members") or [])
                   for s in previous.get("shows", [])
                   if isinstance(s, dict) and s.get("url")
                   and (s.get("detail_done") or s.get("description") or s.get("cast"))}
    # One-run cache buster for the SHOWS feed only: re-scrape every show
    # source and re-fetch every detail page (e.g. after a change to how
    # descriptions are extracted). Classes and talent keep their cadences.
    # The previous stamps are kept so a source that fails on the refresh run
    # still carries its last-good scraped_at instead of None.
    # Usage: REFRESH_DETAILS=1 python publish_static.py
    refresh = bool(os.environ.get("REFRESH_DETAILS"))
    if refresh:
        prev_detail = {}

    # Detail enrichment rides the shared loop as a post-scrape hook; the budget
    # and the wall-clock deadline are shared across sources within one run
    # (the clock starts here, so slow listing fetches eat into detail time
    # rather than into the job timeout).
    budget = [_DETAIL_BUDGET]
    deadline = time.monotonic() + _DETAIL_DEADLINE

    def enrich(src, shows):
        if src.get("detail"):
            budget[0] -= _enrich_details(shows, src["detail"], prev_detail, budget[0],
                                         deadline=deadline)

    all_shows, summary = run_sources(
        SOURCES, previous_items=prev_by_source, prev_scraped=prev_scraped,
        now=now, intervals=_SCRAPE_INTERVALS,
        default_interval=_DEFAULT_SCRAPE_INTERVAL, grace=_SCRAPE_GRACE,
        keep=_is_upcoming, on_scraped=enrich, log=log, force=refresh,
    )
    all_shows.sort(key=lambda s: (s.get("start") or s.get("end") or "9999-12-31"))
    return build_payload(all_shows, summary, now=now)


def build_payload(shows: list[dict], sources: list[dict] | None = None,
                  now: datetime | None = None) -> dict:
    return {
        "generated_at": (now or datetime.now(timezone.utc)).isoformat(),
        "count": len(shows),
        "sources": sources or [],
        "shows": shows,
    }


def scrape() -> dict:
    return aggregate()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    print(json.dumps(scrape(), indent=2, ensure_ascii=False))

"""UCB talent directory aggregator.

Merges the talent pages (NY performers, LA performers, teachers) and the DCM
roster into one payload keyed by profile slug, with each person tagged by the
groups they appear in. Each group has its own cadence stamp (like the show and
class sources in aggregation.run_sources): a group not due, or whose fetch
failed, carries over its people from the previous payload so a transient
block never empties the directory.

Bios are enriched from each person's /people/<slug>/ profile page with a
per-run budget (like show details): bios already fetched carry over from the
previous payload, only new people are fetched, and the cache converges after
a few runs. Override the budget with TALENT_BIO_BUDGET.

Runnable standalone: `python talent.py` prints the JSON payload.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import storage
from aggregation import parse_dt
from sources.ucb_talent import PAGES, bio, fetch_dcm_roster, fetch_page

log = logging.getLogger("ucb.talent")

# The roster changes rarely and a full refresh is ~80 requests (grid pages +
# DCM load-more sweep), so re-scrape each group at most daily (with the same
# early-tick grace as the show/class loop); in-between runs reuse the
# previous payload and only keep converging bios.
_ROSTER_INTERVAL = 24 * 3600
_ROSTER_GRACE = 30 * 60
# When a sweep fails outright (every group it tried errored — the host is
# blocking us), wait this long before trying again instead of re-running the
# full sweep on every 3h tick against a host that is already refusing.
_ROSTER_BACKOFF = 6 * 3600
# A page that suddenly parses to well under its previous head-count is far
# more likely truncated (partial render, markup change) than a real purge;
# treat it as a failed fetch so the group carries instead of shrinking.
_SHRINK_RATIO = 0.6

_DEFAULT_BIO_BUDGET = 150
_BIO_WORKERS = 8
# Wall-clock cap on bio fetching, measured from the start of aggregate_talent
# (so slow roster pages eat into bio time, not into scrape.yml's 20-minute job
# timeout). Bios run last in the job and converge over runs anyway, so this
# is tighter than the shows' detail deadline. Past it no NEW bio fetch starts;
# the rest stay unflagged and are retried next run.
_BIO_DEADLINE = 5 * 60
_PAST_DEADLINE = object()    # safe() result for a fetch skipped by the deadline

_GROUPS = [g for g, _ in PAGES] + ["dcm"]
_GROUP_CITY = {"ny": "New York", "la": "Los Angeles"}   # teachers/dcm span cities


def _bio_budget() -> int:
    """TALENT_BIO_BUDGET, read lazily so a malformed value degrades to the
    default instead of aborting the whole publish at import time."""
    raw = os.environ.get("TALENT_BIO_BUDGET", "").strip()
    if not raw:
        return _DEFAULT_BIO_BUDGET
    try:
        return int(raw)
    except ValueError:
        log.warning("TALENT_BIO_BUDGET=%r is not an int; using %d", raw, _DEFAULT_BIO_BUDGET)
        return _DEFAULT_BIO_BUDGET


def _enrich_bios(people: list[dict], prev_people: list[dict], deadline=None) -> int:
    """Fill `bio` from profile pages: reuse previously fetched bios by slug,
    fetch (in parallel, up to the budget) only people not yet attempted. Each
    processed person is flagged `bio_done` so empty bios aren't re-fetched
    forever. `deadline` is a time.monotonic() instant after which no new fetch
    starts. Returns the number attempted."""
    prev = {p["slug"]: p for p in prev_people
            if p.get("slug") and (p.get("bio_done") or p.get("bio"))}
    to_fetch = []
    for person in people:
        cached = prev.get(person.get("slug"))
        if cached is not None:
            person["bio"] = cached.get("bio", "")
            person["bio_done"] = True
        else:
            to_fetch.append(person)
    to_fetch = to_fetch[:max(0, _bio_budget())]

    def safe(person):
        if deadline is not None and time.monotonic() >= deadline:
            return _PAST_DEADLINE
        try:
            return bio(person["url"])
        except Exception:  # noqa: BLE001 - malformed row / parser error: retry next run
            return None

    if to_fetch:
        with ThreadPoolExecutor(max_workers=_BIO_WORKERS) as ex:
            results = list(ex.map(safe, to_fetch))
        skipped = sum(1 for r in results if r is _PAST_DEADLINE)
        if skipped:
            log.warning("bio deadline reached: %d profile(s) left for the next run", skipped)
        for person, text in zip(to_fetch, results):
            if text is None or text is _PAST_DEADLINE:
                continue    # fetch failed / out of time — leave unflagged so next run retries
            person["bio"] = text
            person["bio_done"] = True
        return len(to_fetch) - skipped
    return 0


def _prev_stamps(previous: dict) -> dict[str, str | None]:
    """Per-group scraped_at from the previous payload's summary rows; payloads
    written before per-group stamps existed (no `scraped_at` key at all) fall
    back to the roster clock. An explicit None is kept as None: that group has
    never scraped successfully and must stay due, not inherit another group's
    success."""
    fallback = previous.get("roster_scraped_at")
    stamps = {}
    for s in previous.get("sources", []):
        if isinstance(s, dict) and s.get("id"):
            stamps[s["id"]] = s["scraped_at"] if "scraped_at" in s else fallback
    return stamps


def _group_due(stamp: str | None, now: datetime) -> bool:
    last = parse_dt(stamp)
    return last is None or (now - last).total_seconds() >= _ROSTER_INTERVAL - _ROSTER_GRACE


def _backing_off(previous: dict, now: datetime) -> bool:
    """True while the last sweep failed outright (attempted after the last
    successful scrape) and it happened less than _ROSTER_BACKOFF ago."""
    attempted = parse_dt(previous.get("roster_attempted_at"))
    scraped = parse_dt(previous.get("roster_scraped_at"))
    if attempted is None or (scraped is not None and scraped >= attempted):
        return False
    return (now - attempted).total_seconds() < _ROSTER_BACKOFF


def aggregate_talent(now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    bio_deadline = time.monotonic() + _BIO_DEADLINE
    previous = storage.load_talent() or {}
    prev_people = [p for p in previous.get("people", []) if isinstance(p, dict)]
    prev_stamps = _prev_stamps(previous)
    prev_counts = {g: sum(1 for p in prev_people if g in (p.get("groups") or []))
                   for g in _GROUPS}

    due = {g for g in _GROUPS if _group_due(prev_stamps.get(g), now)}
    if due and _backing_off(previous, now):
        log.info("talent: last sweep failed outright at %s; backing off (%s due)",
                 previous.get("roster_attempted_at"), sorted(due))
        due = set()

    people: dict[str, dict] = {}   # slug → person
    summary: list[dict] = []

    def merge(p: dict, group: str, extra_dcm: bool = False) -> None:
        entry = people.setdefault(p["slug"], {**p, "groups": []})
        if group not in entry["groups"]:
            entry["groups"].append(group)
        if extra_dcm and "dcm" not in entry["groups"]:
            entry["groups"].append("dcm")
        if not entry.get("image") and p.get("image"):
            entry["image"] = p["image"]

    def row(group: str, count: int, *, stale: bool, scraped_at: str | None,
            error: str | None) -> None:
        summary.append({"id": group, "org": "UCB", "city": _GROUP_CITY.get(group, ""),
                        "count": count, "ok": True if not stale else bool(count),
                        "stale": stale and bool(count), "scraped_at": scraped_at,
                        "error": error})

    def carry_group(group: str, error: Exception | None) -> None:
        carried = skipped = 0
        for prev in prev_people:
            if group not in (prev.get("groups") or []):
                continue
            try:
                merge(prev, group)
                carried += 1
            except (KeyError, TypeError, AttributeError):
                skipped += 1    # malformed previous row: drop it, never abort the publish
        if skipped:
            log.warning("talent group %s: skipped %d malformed carried row(s)", group, skipped)
        row(group, carried, stale=error is not None, scraped_at=prev_stamps.get(group),
            error=None if error is None else str(error))
        if error is None:
            log.info("talent group %s: not due (cadence), carried %d", group, carried)
        else:
            log.warning("talent group %s failed: %r (carried %d)", group, error, carried)

    def check_shrink(group: str, count: int) -> None:
        prev_count = prev_counts.get(group, 0)
        if prev_count and count < prev_count * _SHRINK_RATIO:
            raise RuntimeError(f"ucb_talent: {group} parsed {count} people vs {prev_count} "
                               f"last time (truncated page?)")

    def scrape_group(group: str, fetch) -> None:
        if group not in due:
            carry_group(group, None)
            return
        try:
            fetched = fetch()
            check_shrink(group, len(fetched))
            for p in fetched:
                merge(p, group, extra_dcm=p.pop("dcm", False))
            row(group, len(fetched), stale=False, scraped_at=now.isoformat(), error=None)
            log.info("talent group %s: %d people", group, len(fetched))
        except Exception as e:  # noqa: BLE001 - carry the group from last-good
            carry_group(group, e)

    for group, url in PAGES:
        scrape_group(group, lambda url=url: fetch_page(url))
    # Full DCM roster from the grid's load-more endpoint (the category-class
    # tags above only cover DCM people who are also on the NY/LA/teacher pages).
    scrape_group("dcm", fetch_dcm_roster)

    ordered = sorted(people.values(), key=lambda p: (p.get("name") or "").lower())
    fetched = _enrich_bios(ordered, prev_people, deadline=bio_deadline)
    if fetched:
        log.info("talent bios: fetched %d new (budget %d)", fetched, _bio_budget())

    # Roster clocks: roster_scraped_at is the last time any group scraped;
    # roster_attempted_at the last time any group was tried. A sweep whose
    # every attempt failed leaves scraped < attempted, which is what
    # _backing_off keys on next run; per-group retry timing lives in the
    # summary rows' scraped_at.
    any_scraped = any(s["ok"] and not s["error"] and s["id"] in due for s in summary)
    roster_scraped_at = (now.isoformat() if any_scraped
                         else previous.get("roster_scraped_at"))
    roster_attempted_at = now.isoformat() if due else previous.get("roster_attempted_at")
    return {
        "generated_at": now.isoformat(),
        "roster_scraped_at": roster_scraped_at,
        "roster_attempted_at": roster_attempted_at,
        "count": len(ordered),
        "sources": summary,
        "people": ordered,
    }


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    print(json.dumps(aggregate_talent(), indent=2, ensure_ascii=False))

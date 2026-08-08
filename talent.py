"""UCB talent directory aggregator.

Merges the talent pages (NY performers, LA performers, teachers) into one
payload keyed by profile slug, with each person tagged by the groups they
appear in. A failed page carries over that group's people from the previous
payload so a transient block never empties the directory.

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
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import storage
from sources.ucb_talent import PAGES, bio, fetch_dcm_roster, fetch_page

log = logging.getLogger("ucb.talent")

# The roster changes rarely and a full refresh is ~105 requests (grid pages +
# DCM load-more sweep), so re-scrape at most daily; in-between runs reuse the
# previous payload and only keep converging bios.
_ROSTER_INTERVAL = 24 * 3600

_BIO_BUDGET = int(os.environ.get("TALENT_BIO_BUDGET", "150"))
_BIO_WORKERS = 8


def _enrich_bios(people: list[dict], prev_people: list[dict]) -> int:
    """Fill `bio` from profile pages: reuse previously fetched bios by slug,
    fetch (in parallel, up to the budget) only people not yet attempted. Each
    processed person is flagged `bio_done` so empty bios aren't re-fetched
    forever. Returns the number fetched."""
    prev = {p["slug"]: p for p in prev_people
            if p.get("bio_done") or p.get("bio")}
    to_fetch = []
    for person in people:
        cached = prev.get(person["slug"])
        if cached is not None:
            person["bio"] = cached.get("bio", "")
            person["bio_done"] = True
        else:
            to_fetch.append(person)
    to_fetch = to_fetch[:max(0, _BIO_BUDGET)]
    if to_fetch:
        with ThreadPoolExecutor(max_workers=_BIO_WORKERS) as ex:
            results = list(ex.map(lambda p: bio(p["url"]), to_fetch))
        for person, text in zip(to_fetch, results):
            if text is None:
                continue    # fetch failed — leave unflagged so next run retries
            person["bio"] = text
            person["bio_done"] = True
    return len(to_fetch)


def _roster_due(previous: dict, now: datetime) -> bool:
    raw = previous.get("roster_scraped_at")
    if not raw:
        return True
    try:
        last = datetime.fromisoformat(raw)
    except ValueError:
        return True
    return (now - last).total_seconds() >= _ROSTER_INTERVAL


def aggregate_talent(now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    previous = storage.load_talent() or {}
    prev_people = previous.get("people", [])

    if prev_people and not _roster_due(previous, now):
        # Roster fresh enough — keep converging bios on the previous people.
        people_list = [dict(p) for p in prev_people]
        fetched = _enrich_bios(people_list, prev_people)
        if fetched:
            log.info("talent bios: fetched %d new (roster not due)", fetched)
        return {**previous, "generated_at": now.isoformat(),
                "count": len(people_list), "people": people_list}

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

    def carry_group(group: str, error: Exception) -> None:
        carried = 0
        for prev in prev_people:
            if group in prev.get("groups", []):
                merge(prev, group)
                carried += 1
        summary.append({"id": group, "count": carried, "ok": bool(carried), "error": str(error)})
        log.warning("talent group %s failed: %r (carried %d)", group, error, carried)

    for group, url in PAGES:
        try:
            page_people = fetch_page(url)
            for p in page_people:
                merge(p, group, extra_dcm=p.pop("dcm", False))
            summary.append({"id": group, "count": len(page_people), "ok": True, "error": None})
            log.info("talent page %s: %d people", group, len(page_people))
        except Exception as e:  # noqa: BLE001 - carry the group from last-good
            carry_group(group, e)

    # Full DCM roster from the grid's load-more endpoint (the category-class
    # tags above only cover DCM people who are also on the NY/LA/teacher pages).
    try:
        roster = fetch_dcm_roster()
        for p in roster:
            merge(p, "dcm")
        summary.append({"id": "dcm", "count": len(roster), "ok": True, "error": None})
        log.info("talent dcm roster: %d people", len(roster))
    except Exception as e:  # noqa: BLE001 - carry the group from last-good
        carry_group("dcm", e)

    ordered = sorted(people.values(), key=lambda p: p["name"].lower())
    fetched = _enrich_bios(ordered, prev_people)
    if fetched:
        log.info("talent bios: fetched %d new (budget %d)", fetched, _BIO_BUDGET)

    # Only bump the roster clock when something actually scraped; a total
    # failure keeps the previous stamp so the next 3h run retries instead of
    # waiting out the full 24h interval.
    any_scraped = any(s["ok"] and not s["error"] for s in summary)
    roster_scraped_at = (now.isoformat() if any_scraped
                         else previous.get("roster_scraped_at"))
    return {
        "generated_at": now.isoformat(),
        "roster_scraped_at": roster_scraped_at,
        "count": len(ordered),
        "sources": summary,
        "people": ordered,
    }


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    print(json.dumps(aggregate_talent(), indent=2, ensure_ascii=False))

"""The Annoyance Theatre (Chicago) adapter.

Primary source: ThunderTix's own calendar-feed endpoint
(/reports/calendar?start=<epoch>&end=<epoch>) — the JSON the theatre's
show-calendar widget renders from. One request returns every public
performance in the window (~215 across ~54 productions for two months),
including per-performance sold-out state and a poster. Descriptions and
higher-quality art are enriched once per production from the event page's
schema.org JSON-LD (politely: ThunderTix 429s at ~8 concurrent requests).

A calendar failure raises so the aggregator carries last-good data — there
used to be a ~1-week JSON-LD fallback here, but replacing 180 carried days
with 1 fresh week is strictly worse than a flagged stale carry.
"""
from __future__ import annotations

import json
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

from dateutil import parser as dateparser

from common import clean, fetch_html, local_today, make_show, safe_url, strip_html
from . import crowdwork

TT = "https://theannoyance.thundertix.com"

_HORIZON_DAYS = 180  # the calendar endpoint serves ~6 months in one request;
                     # covers announced holiday runs (one meta fetch per
                     # production keeps the request count modest)
_WORKERS = 3         # ThunderTix rate-limits aggressively (429s at ~8 concurrent)

# Classes live on Crowdwork (the ThunderTix calendar is shows-only).
CLASSES_SLUG = "annoyancetrial"


def fetch_classes() -> list[dict]:
    return crowdwork.fetch_classes(CLASSES_SLUG, "annoyance", "The Annoyance", "Chicago")


def _event_ld(html: str) -> dict | None:
    """The schema.org Event block on a ThunderTix event page."""
    for block in re.findall(r'<script[^>]*application/ld\+json[^>]*>(.*?)</script>', html, re.S):
        try:
            data = json.loads(block)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict) and data.get("@type") == "Event":
            return data
    return None


def _event_meta(eid: int) -> dict:
    """Description / image / venue / free flag from a production's event page.
    Best-effort by design: ANY failure (fetch or JSON-LD shape drift — offers
    can be a list, location a list, etc.) costs only this production's
    metadata, which self-heals on the next daily run."""
    try:
        ev = _event_ld(fetch_html(f"{TT}/events/{eid}"))
        if not ev:
            return {}
        img = ev.get("image")
        if isinstance(img, list):
            img = img[0] if img else None
        offers = ev.get("offers") or {}
        if isinstance(offers, list):
            offers = offers[0] if offers and isinstance(offers[0], dict) else {}
        location = ev.get("location") or {}
        if isinstance(location, list):
            location = location[0] if location and isinstance(location[0], dict) else {}
        return {
            "image": safe_url(img) if isinstance(img, str) else None,
            "venue": clean(location.get("name")),
            "description": strip_html(ev.get("description")),
            "is_free": bool(ev.get("isAccessibleForFree"))
                       or str(offers.get("lowPrice")) in ("0", "0.0", "0.00"),
        }
    except Exception:  # noqa: BLE001 - metadata must never sink the source
        return {}


def fetch(today: date | None = None) -> list[dict]:
    import time as _time

    today = today or local_today("Chicago")
    horizon = today + timedelta(days=_HORIZON_DAYS)

    start_epoch = int(_time.mktime(_time.strptime(today.isoformat(), "%Y-%m-%d")))
    end_epoch = start_epoch + (_HORIZON_DAYS + 1) * 86400
    raw = fetch_html(f"{TT}/reports/calendar?start={start_epoch}&end={end_epoch}")
    performances = json.loads(raw)  # a JSONDecodeError raises too: carry beats garbage
    performances = [p for p in performances
                    if isinstance(p, dict) and p.get("event_id") and p.get("start")
                    and p.get("access_type", "public") == "public"]
    if not performances:
        # The Annoyance always has upcoming shows; an empty window means the
        # endpoint changed shape. Raise so last-good data carries.
        raise RuntimeError("annoyance: calendar endpoint returned no public performances")

    # One metadata fetch per production (not per performance), politely.
    event_ids = sorted({p["event_id"] for p in performances})
    with ThreadPoolExecutor(max_workers=_WORKERS) as ex:
        metas = dict(zip(event_ids, ex.map(_event_meta, event_ids)))

    shows: list[dict] = []
    seen: set[str] = set()
    for p in performances:
        try:
            dt = dateparser.parse(p["start"]).replace(tzinfo=None, microsecond=0)
        except (ValueError, OverflowError, TypeError):
            continue
        if not (today <= dt.date() <= horizon):
            continue
        eid = p["event_id"]
        key = f"{eid}/{dt.isoformat()}"
        if key in seen:
            continue
        seen.add(key)
        title = clean(p.get("longTitle") or p.get("title"))
        if not title:
            continue
        meta = metas.get(eid) or {}
        image = meta.get("image") or safe_url(p.get("picture"))
        description = meta.get("description", "")
        venue = meta.get("venue") or "The Annoyance Theatre"
        shows.append(make_show(
            title=title,
            url=f"{TT}/events/{eid}",
            slug=f"{eid}/{dt.strftime('%Y%m%d%H%M')}",
            date_raw=dt.strftime("%A, %B %-d @ %-I:%M %p"),
            start=dt.isoformat(),
            has_time=True,
            venue=venue,
            venues=[venue],
            comedy_types=[],
            image=image,
            description=description,
            excerpt=description[:240],
            is_free=bool(meta.get("is_free")),
            source="annoyance",
            org="The Annoyance",
            city="Chicago",
        ))
    return shows

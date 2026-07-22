"""The Annoyance Theatre (Chicago) adapter.

Primary source: ThunderTix's own calendar-feed endpoint
(/reports/calendar?start=<epoch>&end=<epoch>) — the JSON the theatre's
show-calendar widget renders from. One request returns every public
performance in the window (~215 across ~54 productions for two months),
including per-performance sold-out state and a poster. Descriptions and
higher-quality art are enriched once per production from the event page's
schema.org JSON-LD (politely: ThunderTix 429s at ~8 concurrent requests).

Fallback: the calendar page's embedded JSON-LD, which only ever exposes about
one week of instances.
"""
from __future__ import annotations

import json
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

from dateutil import parser as dateparser

from common import clean, fetch_html, make_show, safe_url, strip_html
from . import crowdwork

TT = "https://theannoyance.thundertix.com"
URL = f"{TT}/events?display=calendar"

_HORIZON_DAYS = 180  # the calendar endpoint serves ~6 months in one request;
                     # covers announced holiday runs (one meta fetch per
                     # production keeps the request count modest)
_WORKERS = 3         # ThunderTix rate-limits aggressively (429s at ~8 concurrent)

# Classes live on Crowdwork (the ThunderTix calendar is shows-only).
CLASSES_SLUG = "annoyancetrial"


def fetch_classes() -> list[dict]:
    return crowdwork.fetch_classes(CLASSES_SLUG, "annoyance", "The Annoyance", "Chicago")


def _events_from_ldjson(html: str) -> list[dict]:
    events: list[dict] = []
    for block in re.findall(r'<script[^>]*application/ld\+json[^>]*>(.*?)</script>', html, re.S):
        try:
            data = json.loads(block)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict) and data.get("@type") == "ItemList":
            for li in data.get("itemListElement", []):
                item = li.get("item") if isinstance(li, dict) else None
                if isinstance(item, dict) and item.get("@type") == "Event":
                    events.append(item)
    return events


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
    """Description / image / venue / free flag from a production's event page."""
    try:
        ev = _event_ld(fetch_html(f"{TT}/events/{eid}"))
    except RuntimeError:
        ev = None
    if not ev:
        return {}
    img = ev.get("image")
    if isinstance(img, list):
        img = img[0] if img else None
    offers = ev.get("offers") or {}
    return {
        "image": safe_url(img) if isinstance(img, str) else None,
        "venue": clean((ev.get("location") or {}).get("name")),
        "description": strip_html(ev.get("description")),
        "is_free": bool(ev.get("isAccessibleForFree"))
                   or str(offers.get("lowPrice")) in ("0", "0.0", "0.00"),
    }


def fetch(today: date | None = None) -> list[dict]:
    import time as _time

    today = today or date.today()
    horizon = today + timedelta(days=_HORIZON_DAYS)

    start_epoch = int(_time.mktime(_time.strptime(today.isoformat(), "%Y-%m-%d")))
    end_epoch = start_epoch + (_HORIZON_DAYS + 1) * 86400
    try:
        raw = fetch_html(f"{TT}/reports/calendar?start={start_epoch}&end={end_epoch}")
        performances = json.loads(raw)
    except (RuntimeError, json.JSONDecodeError):
        performances = []
    performances = [p for p in performances
                    if isinstance(p, dict) and p.get("event_id") and p.get("start")
                    and p.get("access_type", "public") == "public"]
    if not performances:
        return _fetch_week_calendar()

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
    return shows or _fetch_week_calendar()


def _fetch_week_calendar(today: date | None = None) -> list[dict]:
    """Legacy fallback: the ThunderTix calendar's JSON-LD (~one week of shows)."""
    html = fetch_html(URL)
    events = _events_from_ldjson(html)
    if not events:
        raise RuntimeError("annoyance: no Events found in ThunderTix JSON-LD")

    shows: list[dict] = []
    seen: set[str] = set()
    for ev in events:
        status = ev.get("eventStatus") or ""
        if "Cancelled" in status or "Postponed" in status:
            continue
        title = clean(ev.get("name"))
        start_raw = ev.get("startDate")
        if not title or not start_raw:
            continue
        try:
            dt = dateparser.parse(start_raw)
        except (ValueError, OverflowError, TypeError):
            continue

        url = safe_url(ev.get("url") or (ev.get("offers") or {}).get("url"))
        key = url or title
        if key in seen:
            continue
        seen.add(key)

        start = dt.replace(tzinfo=None, microsecond=0).isoformat()  # naive Central wall-clock
        end_iso = None
        if ev.get("endDate"):
            try:
                end_iso = dateparser.parse(ev["endDate"]).date().isoformat()
            except (ValueError, OverflowError, TypeError):
                pass

        img = ev.get("image")
        if isinstance(img, list):
            img = img[0] if img else None
        image = safe_url(img) if isinstance(img, str) else None

        venue = clean((ev.get("location") or {}).get("name")) or "The Annoyance Theatre"
        offers = ev.get("offers") or {}
        is_free = bool(ev.get("isAccessibleForFree")) or str(offers.get("lowPrice")) in ("0", "0.0", "0.00")

        shows.append(make_show(
            title=title,
            url=url,
            slug=url.rstrip("/").split("/")[-1] if url else "",
            date_raw=dt.strftime("%A, %B %-d @ %-I:%M %p"),
            start=start,
            end=end_iso,
            has_time=True,
            venue=venue,
            venues=[venue],
            comedy_types=[],
            image=image,
            description=strip_html(ev.get("description")),
            excerpt=strip_html(ev.get("description"))[:240],
            is_free=is_free,
            source="annoyance",
            org="The Annoyance",
            city="Chicago",
        ))
    return shows

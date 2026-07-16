"""The Annoyance Theatre (Chicago) adapter.

Two-stage scrape for full coverage: the theatre's Wix site (/shows) is the
index — every production links to its ThunderTix event page — and each event's
ThunderTix pages provide the reliable data: schema.org Event JSON-LD for
metadata plus a /performances page listing every upcoming showtime. The old
single-page ThunderTix calendar only ever exposes ~one week of instances
(its month parameters are ignored server-side), so it remains only as a
fallback for when the Wix index serves a data-less page (which it has
historically done intermittently).
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
WIX_INDEX = "https://www.theannoyance.com/shows"

_HORIZON_DAYS = 42
_WORKERS = 3   # ThunderTix rate-limits aggressively (429s at ~8 concurrent)
_PERF_ROW = re.compile(
    r"(\w+day),?\s+(\w+ \d{1,2},? \d{4})[^<]{0,40}?(\d{1,2}:\d{2}\s*[AP]M)")

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


def _fetch_production(eid: str, today: date, horizon: date) -> list[dict]:
    """One production → one show per upcoming performance within the horizon."""
    ev = _event_ld(fetch_html(f"{TT}/events/{eid}"))
    if not ev:
        return []
    title = clean(ev.get("name"))
    if not title:
        return []
    status = ev.get("eventStatus") or ""
    if "Cancelled" in status or "Postponed" in status:
        return []

    img = ev.get("image")
    if isinstance(img, list):
        img = img[0] if img else None
    image = safe_url(img) if isinstance(img, str) else None
    venue = clean((ev.get("location") or {}).get("name")) or "The Annoyance Theatre"
    offers = ev.get("offers") or {}
    is_free = bool(ev.get("isAccessibleForFree")) or str(offers.get("lowPrice")) in ("0", "0.0", "0.00")
    description = strip_html(ev.get("description"))
    url = f"{TT}/events/{eid}"

    perf_html = fetch_html(f"{TT}/events/{eid}/performances")
    shows: list[dict] = []
    seen: set[str] = set()
    for _, date_txt, time_txt in _PERF_ROW.findall(perf_html):
        try:
            dt = dateparser.parse(f"{date_txt} {time_txt}")
        except (ValueError, OverflowError, TypeError):
            continue
        if not (today <= dt.date() <= horizon) or dt.isoformat() in seen:
            continue
        seen.add(dt.isoformat())
        shows.append(make_show(
            title=title,
            url=url,
            slug=f"{eid}/{dt.strftime('%Y%m%d%H%M')}",
            date_raw=dt.strftime("%A, %B %-d @ %-I:%M %p"),
            start=dt.replace(microsecond=0).isoformat(),
            has_time=True,
            venue=venue,
            venues=[venue],
            comedy_types=[],
            image=image,
            description=description,
            excerpt=description[:240],
            is_free=is_free,
            source="annoyance",
            org="The Annoyance",
            city="Chicago",
        ))
    return shows


def fetch(today: date | None = None) -> list[dict]:
    today = today or date.today()
    horizon = today + timedelta(days=_HORIZON_DAYS)

    try:
        ids = sorted(set(re.findall(r"thundertix\.com/events/(\d+)", fetch_html(WIX_INDEX))))
    except RuntimeError:
        ids = []

    if ids:
        shows: list[dict] = []
        def safe(eid):
            try:
                return _fetch_production(eid, today, horizon)
            except Exception:  # noqa: BLE001 - one bad production must not break the source
                return []
        with ThreadPoolExecutor(max_workers=_WORKERS) as ex:
            for result in ex.map(safe, ids):
                shows.extend(result)
        if shows:
            return shows
        # fall through to the one-week calendar rather than fail empty

    return _fetch_week_calendar()


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

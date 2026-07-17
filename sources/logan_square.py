"""Logan Square Improv (Chicago) adapter.

Their /events/ page is a FullCalendar widget fed by Crowdwork's public API
(crowdwork.com/api/v2/lsi/shows?start=…&end=…) — the same ticketing platform
several theaters use for classes. The API caps ranges at about a month, so we
query month-sized windows covering the two-month horizon. Each show record
carries its full list of occurrence datetimes (ISO with the Chicago UTC
offset), artwork, description HTML, and the Crowdwork event page URL.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta

import json

from common import clean, fetch_html, make_show, safe_url, strip_html

API = "https://crowdwork.com/api/v2/lsi/shows"
_HORIZON_DAYS = 62
_WINDOW_DAYS = 28


def _windows(today: date):
    cursor = today
    horizon = today + timedelta(days=_HORIZON_DAYS)
    while cursor < horizon:
        nxt = min(cursor + timedelta(days=_WINDOW_DAYS), horizon)
        yield cursor, nxt
        cursor = nxt


def fetch(today: date | None = None) -> list[dict]:
    today = today or date.today()
    horizon = today + timedelta(days=_HORIZON_DAYS)

    records: dict[int, dict] = {}
    dates_by_id: dict[int, set[str]] = {}
    errors = 0
    for win_start, win_end in _windows(today):
        url = (f"{API}?start={win_start.isoformat()}T00:00:00"
               f"&end={win_end.isoformat()}T00:00:00")
        try:
            payload = json.loads(fetch_html(url))
        except (RuntimeError, json.JSONDecodeError):
            errors += 1
            continue
        for rec in payload.get("data", []):
            rid = rec.get("id")
            if not rid:
                continue
            records.setdefault(rid, rec)
            dates_by_id.setdefault(rid, set()).update(rec.get("dates") or [])
    if not records and errors:
        raise RuntimeError("logan_square: all Crowdwork window fetches failed")

    shows: list[dict] = []
    for rid, rec in records.items():
        title = clean(rec.get("name"))
        if not title:
            continue
        url = safe_url(rec.get("url"))
        img = rec.get("img") or {}
        image = safe_url(img.get("large") or img.get("url")) if isinstance(img, dict) else None
        desc_body = (rec.get("description") or {}).get("body", "") if isinstance(rec.get("description"), dict) else ""
        description = strip_html(desc_body)

        for iso in sorted(dates_by_id.get(rid, [])):
            try:
                dt = datetime.fromisoformat(iso).replace(tzinfo=None, microsecond=0)
            except ValueError:
                continue
            if not (today <= dt.date() <= horizon):
                continue
            shows.append(make_show(
                title=title,
                url=url,
                slug=f"{rid}/{dt.strftime('%Y%m%d%H%M')}",
                date_raw=dt.strftime("%A, %B %-d @ %-I:%M %p"),
                start=dt.isoformat(),
                has_time=True,
                venue="Logan Square Improv",
                venues=["Logan Square Improv"],
                comedy_types=["Improv"],   # the API's `tags` are visibility flags, not genres
                image=image,
                description=description[:2000],
                excerpt=description[:240],
                is_free=False,
                source="logan_square",
                org="Logan Square Improv",
                city="Chicago",
            ))
    if not shows:
        raise RuntimeError("logan_square: no upcoming showtimes parsed")
    return shows

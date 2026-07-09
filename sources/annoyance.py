"""The Annoyance Theatre (Chicago) adapter.

Scraped from their ThunderTix ticketing calendar, which embeds reliable
schema.org Event data as JSON-LD (an ItemList of Events). This is far more stable
than the theatre's own Wix site, which intermittently served a data-less page.
"""
from __future__ import annotations

import json
import re
from datetime import date

from dateutil import parser as dateparser

from common import clean, fetch_html, make_show, safe_url, strip_html
from . import crowdwork

URL = "https://theannoyance.thundertix.com/events?display=calendar"

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


def fetch(today: date | None = None) -> list[dict]:
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

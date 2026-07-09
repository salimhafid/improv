"""UCB classes (New York + Los Angeles) via the Arlo public REST API.

ucbcomedy.com's course pages are Cloudflare-protected + client-rendered, but the
data is served as JSON by Arlo (ucbcomedy.arlo.co). We page through eventsearch
once (memoized) and split sessions by Arlo location tag (LOC_NY / LOC_LA).
"""
from __future__ import annotations

import re
import time
from datetime import datetime
from urllib.parse import quote

from common import clean, fetch_json, make_class, strip_html

ARLO_BASE = "https://ucbcomedy.arlo.co/api/2012-02-01/pub/resources/"
# Arlo's ViewUri (?arlo_id=<courseTemplate>) just lands on the UCB home page, and
# the arlo.co hosted pages 404. UCB's only working deep link is its own course
# catalog (a JS widget) filtered by a search term — lands on the class.
CATALOG_SEARCH = "https://ucbcomedy.com/training-center/course/#1-search=%s"
_FIELDS = ("EventID,Name,StartDateTime,Summary,ViewUri,IsFull,"
           "Location,Categories,Tags,Presenters,AdvertisedOffers")
_EXPAND = "Categories,Presenters,AdvertisedOffers,Location"

# Memo the (paged) event list so the NY and LA passes in one aggregate don't
# each re-page the whole catalog.
_memo: tuple[float, list] | None = None
_MEMO_TTL = 120.0


def _events() -> list[dict]:
    global _memo
    if _memo and (time.monotonic() - _memo[0]) < _MEMO_TTL:
        return _memo[1]
    items: list[dict] = []
    skip = 0
    while skip <= 5000:
        url = (f"{ARLO_BASE}eventsearch/?format=json&top=100&skip={skip}"
               f"&fields={_FIELDS}&expand={_EXPAND}")
        data = fetch_json(url)
        batch = data.get("Items", []) or []
        items.extend(batch)
        if not data.get("NextPageUri") or not batch:
            break
        skip += 100
    _memo = (time.monotonic(), items)
    return items


def _price(offers) -> str:
    if not offers:
        return ""
    amt = (offers[0] or {}).get("OfferAmount") or {}
    return amt.get("FormattedAmountTaxInclusive") or amt.get("FormattedAmountTaxExclusive") or ""


def _build(loc_tag: str, source: str, org: str, city: str) -> list[dict]:
    out: list[dict] = []
    for ev in _events():
        if loc_tag not in (ev.get("Tags") or []):
            continue
        title = clean(ev.get("Name"))
        if not title:
            continue
        start_raw = ev.get("StartDateTime") or ""
        start = start_raw[:19] if len(start_raw) >= 19 and start_raw[10] == "T" else None
        schedule = ""
        if start:
            try:
                schedule = datetime.strptime(start, "%Y-%m-%dT%H:%M:%S").strftime("%A, %B %-d @ %-I:%M %p")
            except ValueError:
                schedule = start
        cats = ev.get("Categories") or []
        level = re.sub(r"^\d+\.\s*", "", clean((cats[0] or {}).get("Name"))) if cats else ""
        instructor = ", ".join(clean(p.get("Name")) for p in (ev.get("Presenters") or []) if p.get("Name"))
        term = title.split(":")[0].strip() or title  # course name, e.g. "Improv 101"
        out.append(make_class(
            id=f"{source}/{ev.get('EventID')}",
            title=title,
            url=CATALOG_SEARCH % quote(term),
            instructor=instructor,
            schedule=schedule,
            start=start,
            price=_price(ev.get("AdvertisedOffers")),
            level=level,
            description=strip_html(ev.get("Summary")),
            is_full=bool(ev.get("IsFull")),
            source=source, org=org, city=city,
        ))
    return out


def fetch_ny() -> list[dict]:
    return _build("LOC_NY", "ucb_ny", "UCB", "New York")


def fetch_la() -> list[dict]:
    return _build("LOC_LA", "ucb_la", "UCB", "Los Angeles")

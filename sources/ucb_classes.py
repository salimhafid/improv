"""UCB classes (New York, Los Angeles and Online) via the Arlo public REST API.

ucbcomedy.com's course pages are Cloudflare-protected + client-rendered, but the
data is served as JSON by Arlo (ucbcomedy.arlo.co). We page through eventsearch
once (memoized) and split sessions by location tags or their venue metadata.
"""
from __future__ import annotations

import logging
import re
import time
from datetime import datetime
from urllib.parse import parse_qs, urlencode, urlsplit

from common import clean, fetch_json, make_class, strip_html

log = logging.getLogger("ucb.classes.source")

ARLO_BASE = "https://ucbcomedy.arlo.co/api/2012-02-01/pub/resources/"
# UCB's supported course resolver redirects to the canonical course permalink
# and preserves `event`, selecting this exact session (not every Improv 101).
# Arlo's raw ViewUri points at the old home-page route; use its template ID
# with the current /courses/ resolver, as UCB's own catalog does.
COURSE_URL = "https://ucbcomedy.com/courses/"
_FIELDS = ("EventID,ViewUri,Name,StartDateTime,Summary,IsFull,Location,"
           "Categories,Tags,Presenters,AdvertisedOffers")
_EXPAND = "Categories,Presenters,AdvertisedOffers,Location"
_LOCATION_TAGS = ("LOC_NY", "LOC_LA", "LOC_Online")

# Memo the (paged) event list so the NY, LA and Online passes in one aggregate
# don't each re-page the whole catalog. A failed walk is memoised too (as the
# error) so a mid-walk outage is not re-walked three times per run.
_memo: tuple[float, list | Exception] | None = None
_MEMO_TTL = 120.0


def event_location_tags(event: dict) -> list[str]:
    """Route a published session even before its optional LOC tag is assigned.

    Explicit location tags take precedence, including unsupported locations
    such as LOC_TX. Only an event without any LOC tag may use venue metadata.
    These exact names/cities mirror Arlo's public UCB locations; class titles,
    descriptions and ambiguous state-only addresses do not establish a city.
    """
    tags = event.get("Tags") or []
    if not isinstance(tags, (list, tuple)):
        tags = []
    location_tags = [tag for tag in tags if isinstance(tag, str) and tag.startswith("LOC_")]
    if location_tags:
        return [tag for tag in _LOCATION_TAGS if tag in location_tags]
    location = event.get("Location")
    if not isinstance(location, dict):
        return []
    name = clean(location.get("Name")).casefold()
    if location.get("IsOnline") is True or name == "online":
        return ["LOC_Online"]
    country = clean(location.get("Country")).casefold()
    if country and country not in {"united states", "united states of america", "us", "usa"}:
        return []
    city = clean(location.get("City")).casefold()
    if re.match(r"^ny\s*:", name) or city in {"new york", "new york city"}:
        return ["LOC_NY"]
    if re.match(r"^la\s*:", name) or city == "los angeles":
        return ["LOC_LA"]
    return []


def _events() -> list[dict]:
    global _memo
    if _memo and (time.monotonic() - _memo[0]) < _MEMO_TTL:
        if isinstance(_memo[1], Exception):
            raise RuntimeError(f"ucb_classes: Arlo walk failed earlier this run: {_memo[1]}")
        return _memo[1]
    try:
        items = _walk()
    except Exception as e:
        _memo = (time.monotonic(), e)
        raise
    _memo = (time.monotonic(), items)
    return items


def _walk() -> list[dict]:
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
        # Advance by what Arlo actually returned — if it ever pages at <100,
        # a fixed +100 stride would silently skip records.
        skip += len(batch)
    # Log once per API walk, rather than once for each city using the memo.
    # Explicit other-city tags are expected; unassigned sessions need review.
    for event in items:
        tags = event.get("Tags") or []
        has_location_tag = isinstance(tags, (list, tuple)) and any(
            isinstance(tag, str) and tag.startswith("LOC_") for tag in tags)
        if event.get("EventID") and clean(event.get("Name")) and not has_location_tag:
            inferred = event_location_tags(event)
            if inferred:
                log.info("UCB session routed from venue id=%s title=%r location=%r routes=%s",
                         event["EventID"], clean(event["Name"]), event.get("Location"), inferred)
            else:
                log.warning("unassigned UCB session id=%s title=%r location=%r",
                            event["EventID"], clean(event["Name"]), event.get("Location"))
    return items


def _price(offers) -> str:
    if not offers:
        return ""
    amt = (offers[0] or {}).get("OfferAmount") or {}
    return amt.get("FormattedAmountTaxInclusive") or amt.get("FormattedAmountTaxExclusive") or ""


def registration_url(event: dict) -> str:
    """Resolve the source's course template and exact session without guessing a slug.

    Missing identifiers must fail the source and retain its last-good feed,
    rather than publishing a Register button that opens an unrelated catalog.
    Only numeric source IDs are used; the source's URL host is never followed.
    """
    view_uri = event.get("ViewUri")
    if not isinstance(view_uri, str):
        raise ValueError("UCB class is missing its course-template URL")
    template_ids = parse_qs(urlsplit(view_uri).query).get("arlo_id", [])
    event_id = str(event.get("EventID") or "")
    if (len(template_ids) != 1 or not re.fullmatch(r"[1-9][0-9]*", template_ids[0])
            or not re.fullmatch(r"[1-9][0-9]*", event_id)):
        raise ValueError("UCB class is missing valid course-template/session identifiers")
    return COURSE_URL + "?" + urlencode({"eventtemplate": template_ids[0], "event": event_id})


def _build(loc_tag: str, source: str, org: str, city: str) -> list[dict]:
    out: list[dict] = []
    for ev in _events():
        if loc_tag not in event_location_tags(ev):
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
        # Arlo's Summary is usually just "Category: Improv & Musical Improv" —
        # a duplicate of `level`, not a description; publish only real copy.
        summary = strip_html(ev.get("Summary"))
        description = "" if summary.lower().startswith("category:") else summary
        out.append(make_class(
            id=f"{source}/{ev.get('EventID')}",
            title=title,
            url=registration_url(ev),
            instructor=instructor,
            schedule=schedule,
            start=start,
            price=_price(ev.get("AdvertisedOffers")),
            level=level,
            description=description,
            is_full=bool(ev.get("IsFull")),
            source=source, org=org, city=city,
        ))
    return out


def fetch_ny() -> list[dict]:
    return _build("LOC_NY", "ucb_ny", "UCB", "New York")


def fetch_la() -> list[dict]:
    return _build("LOC_LA", "ucb_la", "UCB", "Los Angeles")


def fetch_online() -> list[dict]:
    return _build("LOC_Online", "ucb_online", "UCB", "Online")


def raw_events() -> list[dict]:
    """The full tagged Arlo event list (paged, memoized) — used by the
    class-alert watcher, which needs LOC_* and CTG_* tags directly."""
    return _events()

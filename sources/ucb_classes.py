"""UCB classes (New York, Los Angeles and Online) via the Arlo public REST API.

ucbcomedy.com's course pages are Cloudflare-protected + client-rendered, but the
data is served as JSON by Arlo (ucbcomedy.arlo.co). We page through eventsearch
once (memoized) and split sessions by location tags or their venue metadata.

Two requests, one walk each per run: the class-alert watcher (raw_events) keeps
the light field list it polls every ~2 minutes; the daily feed build asks the
same search for the course copy, the meeting pattern and each session's venue
as well (about 1.1 MB instead of 0.14 MB for the catalog, still two pages).
"""
from __future__ import annotations

import logging
import re
import time
from collections import Counter
from datetime import datetime
from urllib.parse import parse_qs, urlencode, urlsplit

from bs4 import BeautifulSoup

from common import block_text, clean, fetch_json, make_class, strip_html

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
# Feed build only: Sessions is the one place Arlo publishes the street address
# and the number of meetings (the event-level Location is usually just a name).
_FEED_FIELDS = _FIELDS + ",EndDateTime,Description,SessionsDescription,Sessions"
_FEED_EXPAND = _EXPAND + ",Sessions"
_LOCATION_TAGS = ("LOC_NY", "LOC_LA", "LOC_Online")

# Memo the (paged) event list so the NY, LA and Online passes in one aggregate
# don't each re-page the whole catalog. A failed walk is memoised too (as the
# error) so a mid-walk outage is not re-walked three times per run. Keyed by
# request: False = the watcher's light walk, True = the feed's detailed one.
_memo: dict[bool, tuple[float, list | Exception]] | None = None
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


def _events(detailed: bool = False) -> list[dict]:
    global _memo
    memo = (_memo or {}).get(detailed)
    if memo and (time.monotonic() - memo[0]) < _MEMO_TTL:
        if isinstance(memo[1], Exception):
            raise RuntimeError(f"ucb_classes: Arlo walk failed earlier this run: {memo[1]}")
        return memo[1]
    try:
        items = _walk(_FEED_FIELDS, _FEED_EXPAND) if detailed else _walk()
    except Exception as e:
        _memo = {**(_memo or {}), detailed: (time.monotonic(), e)}
        raise
    _memo = {**(_memo or {}), detailed: (time.monotonic(), items)}
    return items


def _walk(fields: str = _FIELDS, expand: str = _EXPAND) -> list[dict]:
    items: list[dict] = []
    skip = 0
    while skip <= 5000:
        url = (f"{ARLO_BASE}eventsearch/?format=json&top=100&skip={skip}"
               f"&fields={fields}&expand={expand}")
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


def _description(ev: dict) -> str:
    """The course copy as plain paragraphs, without the teacher biography some
    workshops append (a paragraph opening "<presenter name> is ..." or
    "Instructor bio"). "" when Arlo has no Description for the event."""
    desc = ev.get("Description")
    html = desc.get("Text") if isinstance(desc, dict) else None
    if not isinstance(html, str) or not html.strip():
        return ""
    # Source line wraps and &nbsp; spacers are layout, not paragraph breaks.
    text = block_text(BeautifulSoup(re.sub(r"\s+", " ", html), "lxml")).replace("\xa0", " ")
    names = [clean(p.get("Name")).casefold() for p in (ev.get("Presenters") or [])
             if isinstance(p, dict) and p.get("Name")]
    paragraphs = []
    for para in text.split("\n\n"):
        para = "\n".join(line for line in (clean(l) for l in para.split("\n")) if line)
        # Copy pasted with hard-wrapped lines (<br> mid-sentence, ~70 columns):
        # a long line that runs on into a lowercase word is one sentence.
        para = re.sub(r"(?<=[^\n]{40})(?<![.!?:;])\n(?=[a-z])", " ", para)
        low = para.casefold()
        if not para or low.startswith("instructor bio") or any(low.startswith(n + " is ") for n in names):
            continue
        paragraphs.append(para)
    return "\n\n".join(paragraphs)


def _sessions(ev: dict) -> list[dict]:
    sessions = ev.get("Sessions")
    return [s for s in sessions if isinstance(s, dict)] if isinstance(sessions, list) else []


def _schedule(ev: dict, start: str | None) -> str:
    """"Sundays 11am-2pm ET · Nov 29 - Jan 31 · 8 sessions + class show": Arlo's
    meeting pattern, the first-to-last session dates and the number of class
    meetings. Without a pattern (one-off workshops) the first session's date
    and time stand in for it, as before."""
    first = None
    if start:
        try:
            first = datetime.strptime(start, "%Y-%m-%dT%H:%M:%S")
        except ValueError:
            return start
    end_raw = ev.get("EndDateTime")
    last = None
    if first and isinstance(end_raw, str):
        try:
            last = datetime.strptime(end_raw[:19], "%Y-%m-%dT%H:%M:%S")
        except ValueError:
            pass
    parts = []
    pattern = re.sub(r"^Duration\s+", "", clean(ev.get("SessionsDescription")), flags=re.I)
    if pattern:
        parts.append(pattern)
    elif first:
        line = first.strftime("%A, %B %-d @ %-I:%M %p")
        if last and last.date() == first.date() and last > first:
            line += last.strftime(" - %-I:%M %p")
        parts.append(line)
    if first and last and last.date() > first.date():
        parts.append(f"{first.strftime('%b %-d')} - {last.strftime('%b %-d')}")
    elif first and pattern:
        parts.append(first.strftime("%b %-d"))
    # The class show and its tech rehearsal are sessions in Arlo, but UCB's
    # own copy counts class meetings only ("8 sessions ... a class performance").
    names = [clean(s.get("Name")).casefold() for s in _sessions(ev)]
    extras = [n for n in names if "show" in n or "rehearsal" in n]
    meetings = len(names) - len(extras) or len(names)
    if meetings > 1:
        show = len(extras) < len(names) and any("show" in n for n in extras)
        parts.append(f"{meetings} sessions" + (" + class show" if show else ""))
    return " · ".join(parts)


def _location(ev: dict, loc_tag: str) -> str:
    """"<venue>, <street>, <city>" of the venue most sessions meet at (the
    class show is often on another stage), else of the event's own Location
    when it carries an address; "Online" for an online class."""
    if loc_tag == "LOC_Online":
        return "Online"
    venues = [s["Location"] for s in _sessions(ev) if isinstance(s.get("Location"), dict)]
    if venues:
        key = Counter((clean(v.get("VenueName")), clean(v.get("StreetLine1"))) for v in venues).most_common(1)[0][0]
        venue = next(v for v in venues if (clean(v.get("VenueName")), clean(v.get("StreetLine1"))) == key)
    else:
        venue = ev.get("Location") if isinstance(ev.get("Location"), dict) else {}
    if venue.get("IsOnline") is True or "online" in (clean(venue.get("Name")).casefold(),
                                                     clean(venue.get("City")).casefold()):
        return "Online"
    street = clean(venue.get("StreetLine1"))
    if not street:
        return ""       # a bare campus label ("NY: Union Square") is not an address
    parts = [clean(venue.get("VenueName")), street, clean(venue.get("StreetLine2")), clean(venue.get("City"))]
    return ", ".join(p for p in parts if p)


def _build(loc_tag: str, source: str, org: str, city: str) -> list[dict]:
    out: list[dict] = []
    for ev in _events(detailed=True):
        if loc_tag not in event_location_tags(ev):
            continue
        title = clean(ev.get("Name"))
        if not title:
            continue
        start_raw = ev.get("StartDateTime") or ""
        start = start_raw[:19] if len(start_raw) >= 19 and start_raw[10] == "T" else None
        schedule = _schedule(ev, start)
        cats = ev.get("Categories") or []
        level = re.sub(r"^\d+\.\s*", "", clean((cats[0] or {}).get("Name"))) if cats else ""
        instructor = ", ".join(clean(p.get("Name")) for p in (ev.get("Presenters") or []) if p.get("Name"))
        # Arlo's Summary is usually just "Category: Improv & Musical Improv" —
        # a duplicate of `level`, not a description; publish only real copy.
        # The event's Description is the real course copy; Summary only stands
        # in when it is missing. Some Summaries wrap the label in quotes.
        summary = strip_html(ev.get("Summary"))
        description = _description(ev) or (
            "" if summary.lstrip("\"'\u201c\u2018 ").lower().startswith("category:") else summary)
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
            location=_location(ev, loc_tag),
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

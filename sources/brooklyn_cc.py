"""Brooklyn Comedy Collective adapter. Shows: the Squarespace Events
collection, exposed cleanly as JSON via the `?format=json` view. Classes:
BCC's Crowdwork (Fourth Wall) box office, which the school's class pages embed
since the Squarespace class-registration store was emptied (Nov 2026)."""
from __future__ import annotations

import re
from datetime import date, datetime
from zoneinfo import ZoneInfo

from bs4 import BeautifulSoup
from dateutil import parser as dateparser

from common import block_text, clean, fetch_json, local_today, make_class, make_show, safe_url, strip_html

from . import crowdwork

URL = "https://www.brooklyncc.com/show-schedule?format=json"
BASE = "https://www.brooklyncc.com"
# Classes: the theatre slug of the Crowdwork embeds on brooklyncc.com/comedy-classes.
CROWDWORK_SLUG = "brooklyncomedycollective"
NY = ZoneInfo("America/New_York")


def _ms_to_local(ms) -> datetime | None:
    if not isinstance(ms, (int, float)):
        return None
    return datetime.fromtimestamp(ms / 1000, tz=NY)


def fetch() -> list[dict]:
    data = fetch_json(URL)
    items = data.get("upcoming") or data.get("items") or []
    shows: list[dict] = []
    for it in items:
        title = clean(it.get("title"))
        if not title:
            continue
        start_dt = _ms_to_local(it.get("startDate"))
        end_dt = _ms_to_local(it.get("endDate"))
        start_iso = start_dt.replace(tzinfo=None, microsecond=0).isoformat() if start_dt else None
        end_iso = end_dt.replace(tzinfo=None, microsecond=0).date().isoformat() if end_dt else None
        date_raw = start_dt.strftime("%A, %B %-d, %Y @ %-I:%M %p") if start_dt else ""

        full = it.get("fullUrl") or ""
        url = safe_url(BASE + full) if full.startswith("/") else safe_url(full)
        slug = full.rstrip("/").split("/")[-1] if full else ""
        title_l = title.lower()
        if title_l.startswith("no show"):
            continue    # "No Shows - Labor Day Weekend": a closure notice, not a show
        # Squarespace categories are the rooms (Eris Mainstage / Eris Deep
        # Space / BCC Pig Pen), so they are the venue, not comedy types.
        rooms = [c for c in (clean(c) for c in (it.get("categories") or [])) if c][:3]

        shows.append(make_show(
            title=title,
            url=url,
            slug=slug,
            date_raw=date_raw,
            start=start_iso,
            end=end_iso,
            has_time=start_dt is not None,
            venue=rooms[0] if rooms else "Brooklyn Comedy Collective",
            venues=rooms or ["Brooklyn Comedy Collective"],
            comedy_types=[],
            image=safe_url(it.get("assetUrl")) or None,
            description=strip_html(it.get("body")) or strip_html(it.get("excerpt")),
            excerpt=strip_html(it.get("excerpt")),
            is_free=("free" in title_l or "open mic" in title_l),
            source="brooklyn_cc",
            org="Brooklyn Comedy Collective",
            city="New York",
        ))
    return shows


# MARK: Classes

def _class_level(title: str) -> str:
    """Coarse discipline bucket for grouping (Improv / Musical Improv / Stand-Up /
    Sketch / Clown / Drop-In / Intensive / Workshop). Matches the discipline
    anywhere (titles like 'Intro to BCC Improv' aren't prefixed by it)."""
    low = re.sub(r"^\s*\[[^\]]*\]\s*", "", title).lower()  # drop a leading [Virtual]/[Online] tag
    # Festival (FAD) one-off workshops are their own group on BCC's site, even
    # though their titles mention a discipline — keep them out of the level groups
    # so guest workshops are findable.
    if "workshop" in low or re.search(r"\bfad\b", low):
        return "Workshop"
    if "drop-in" in low or "drop in" in low:
        return "Drop-In"
    if "intensive" in low:
        return "Intensive"
    for kw, label in (("musical improv", "Musical Improv"), ("improv", "Improv"),
                      ("stand-up", "Stand-Up"), ("stand up", "Stand-Up"),
                      ("standup", "Stand-Up"), ("sketch", "Sketch"),
                      ("clown", "Clown"), ("storytelling", "Storytelling")):
        if kw in low:
            return label
    return "Workshop"


def _class_instructor(title: str) -> str:
    # Anchored on " w/ " so "Sketch Show/Workshop" doesn't yield "Workshop".
    m = re.search(r"(?:^|\s)w/\s*(.+?)\s*(?:\(|$)", title)
    return clean(m.group(1)) if m else ""


_TITLE_DATE = re.compile(r"\(\s*(?:[A-Za-z]+,\s*)?([A-Za-z]+ \d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\s*\)")


def _class_start(title: str) -> str | None:
    """Fallback for a listing that publishes no session dates. Drop-ins and
    workshops carry their date in the title — '(Saturday, September 12th,
    2026)' — so they can age out of the feed. Multi-week levels only say
    "(Aug-Oct '26)" and stay undated: there is no day to start from, and a
    made-up first-of-month would drop them mid-run."""
    m = _TITLE_DATE.search(title)
    if not m:
        return None
    try:
        return dateparser.parse(f"{m.group(1)} {m.group(2)}").date().isoformat()
    except (ValueError, OverflowError):
        return None


def _class_schedule(title: str) -> str:
    return " · ".join(clean(p) for p in re.findall(r"\(([^)]+)\)", title) if clean(p))


# The class copy ends with labelled lines about the teacher ("Teacher: Andy
# Junk", then "Bio:", "Testimonials:", "Accompanist:"); everything from the
# first of them on is about the person, not the class.
_TEACHER_LINE = re.compile(r"^Teachers?\s*:\s*(.+)$", re.I | re.M)
_PEOPLE_LINE = re.compile(r"^(?:Teachers?|Bio|(?:Student )?Testimonials?|(?:Musical )?Accompanist)\s*:",
                          re.I | re.M)
_WHERE_LINE = re.compile(r"^Where\s*:\s*(.+)$", re.I | re.M)
_ROOM_AND_STREET = re.compile(r"(.+?)\s*\(([^()]+)\)\.?")
_TIME = r"\d{1,2}(?::\d{2})?\s*[ap]\.?m\.?"
_TIME_RANGE = re.compile(rf"({_TIME})\s*(?:-|–|to)\s*({_TIME})", re.I)


def _class_copy(it: dict) -> str:
    """The item's description body as paragraph-preserving plain text."""
    desc = it.get("description")
    body = desc.get("body") if isinstance(desc, dict) else None
    if not isinstance(body, str) or not body.strip():
        return ""
    return block_text(BeautifulSoup(body, "lxml"))


def _copy_teacher(copy: str) -> str:
    m = _TEACHER_LINE.search(copy)
    name = clean(m.group(1)) if m else ""
    return "" if name.upper() in ("TBD", "TBA") else name


def _class_description(copy: str) -> str:
    m = _PEOPLE_LINE.search(copy)
    return (copy[:m.start()] if m else copy).strip()


def _street(text: str) -> str:
    """'137 Montrose Ave, Brooklyn, NY 11206' / '144 Boerum St' → '<street>,
    Brooklyn' (every BCC room is in East Williamsburg, Brooklyn)."""
    street = re.sub(r",?\s*Brooklyn\b.*$", "", text, flags=re.I).strip(" ,")
    return f"{street}, Brooklyn"


def _class_location(it: dict, copy: str) -> str:
    """One line from, in order: the copy's "Where: <room> (<street>)" line, the
    item's own location ("<room> (<street>)", a bare street address, or the
    school's standing "our classes meet at … in …" note for terms whose rooms
    are assigned by email). "Online" for a virtual class; "" otherwise."""
    listed = clean(it.get("location")) or clean(it.get("venue"))
    if re.search(r"\b(?:virtual|online)\b", listed, re.I) or re.match(
            r"\s*\[(?:virtual|online)\]", clean(it.get("name")), re.I):
        return "Online"
    where = _WHERE_LINE.search(copy)
    for text in (clean(where.group(1)) if where else "", listed):
        m = _ROOM_AND_STREET.fullmatch(text)
        if m and re.match(r"\d", m.group(2)):
            return f"{m.group(1)}, {_street(m.group(2))}"
    if re.match(r"\d+\w* \S", listed) and len(listed) <= 60:
        return _street(listed)
    m = re.search(r"\bmeet at (.+?) in ([^.]+)\.", listed)
    return f"{m.group(1)}, {m.group(2)}" if m else ""


def _clock(text: str) -> str:
    """'7:00 PM' / '3:30pm' → '7pm' / '3:30pm'."""
    return re.sub(r"[\s.]", "", text).lower().replace(":00", "")


def _sessions_schedule(run: list[datetime], copy: str) -> str:
    """'Mondays 7pm-10pm · Jan 4 - Feb 22 · 7 sessions' from every session the
    listing publishes; 'Thursday, Nov 12 · 7pm-9:30pm' for a single one. The
    end time comes from the copy, and only from a time range that starts when
    the listed sessions do."""
    first = run[0]
    times = _clock(first.strftime("%-I:%M%p"))
    for m in _TIME_RANGE.finditer(copy):
        if _clock(m.group(1)) == times:
            times = f"{times}-{_clock(m.group(2))}"
            break
    if len(run) == 1:
        return f"{first.strftime('%A, %b %-d')} · {times}"
    span = f"{first.strftime('%b %-d')} - {run[-1].strftime('%b %-d')}"
    weekly = all(d.weekday() == first.weekday() and d.time() == first.time() for d in run)
    return " · ".join(x for x in (f"{first.strftime('%A')}s {times}" if weekly else "",
                                  span, f"{len(run)} sessions") if x)


def fetch_classes(today: date | None = None) -> list[dict]:
    """Every active class in BCC's Crowdwork catalog; one request. Each item
    carries all of its session dates, its price, room and the class copy, so
    rows are complete here (no per-class pages). Ids use Crowdwork's numeric
    id: the URL slug changes whenever the school retitles a class, which
    would re-alert it."""
    today = today or local_today("New York")
    out: list[dict] = []
    for it in crowdwork._fetch(CROWDWORK_SLUG, "classes"):
        if not isinstance(it, dict):
            continue
        c = crowdwork._common(it)
        title = c["title"]
        if not c["active"] or not title:
            continue
        copy = _class_copy(it)
        dates = it.get("dates")
        candidates = [c["next_date"]] + (dates if isinstance(dates, list) else [])
        run = sorted({d for d in (crowdwork._parse_local(x) for x in candidates) if d})
        if run:
            upcoming = [d for d in run if d.date() >= today]
            if not upcoming:
                continue    # the run is over
            start, schedule = upcoming[0].isoformat(), _sessions_schedule(run, copy)
        else:
            # No session dates published: undated unless the title names a day.
            start, schedule = _class_start(title), _class_schedule(title)
        out.append(make_class(
            id=f"brooklyn_cc/{clean(it.get('id')) or c['slug']}",
            title=title,
            url=c["url"],
            instructor=_copy_teacher(copy) or _class_instructor(title),
            schedule=schedule,
            start=start,
            price=clean(c["cost"]),
            level=_class_level(title),
            image=c["image"],
            description=_class_description(copy) or strip_html(it.get("description_short")),
            location=_class_location(it, copy),
            is_full=crowdwork._is_full(it),
            source="brooklyn_cc", org="Brooklyn Comedy Collective", city="New York",
        ))
    return out

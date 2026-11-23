"""UCB's public registration catalog, shared by the class feed and alert watcher."""
from __future__ import annotations

import json
import logging
import re
import time
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from zoneinfo import ZoneInfo

from bs4 import BeautifulSoup

from common import CITY_TZ, block_text, clean, fetch_html, local_today, make_class

log = logging.getLogger("ucb.classes.source")

CATALOG_URL = "https://ucbcomedy.com/training-center/course/"
_SCHOOLS = {"New York": "ucb_ny", "Los Angeles": "ucb_la", "Online": "ucb_online"}
# Some published sections have no data-cat tags while still belonging to a
# clearly labeled catalog group (e.g. Acting or Improv Workshops & Drop-Ins).
_GROUP_CATEGORIES = {
    "Acting": ("acting",), "Character": ("sketch-and-character",),
    "Clowning": ("clowning",), "Featured Programs": ("featured-programs",),
    "Improv Electives": ("improv-electives",), "Advanced Study Improv": ("improv",),
    "Improv Workshops & Drop-Ins": ("improv", "workshop"), "Musical Improv": ("musical-improv",),
    "Sketch Electives": ("sketch-electives",), "Stand-Up": ("stand-up",),
    "Writing Programs": ("writing-programs",), "Improv": ("improv",),
    "Improv & Musical Improv": ("improv",), "Sketch & Character": ("sketch-and-character",),
    "Sketch and Character": ("sketch-and-character",),
}
# UCB replaced Arlo in November 2026. Keep the feed and watcher's existing IDs
# for migrated sections. New sections use the course slug AND section number:
# different courses reuse the same number, including leading zeroes.
_LEGACY_IDS = json.loads(Path(__file__).with_name("ucb_section_ids.json").read_text())
_SECTION_PATH = re.compile(r"/course/([\w-]+)/(\d+)/", flags=re.ASCII)
_memo: tuple[float, list | Exception] | None = None
_MEMO_TTL = 120.0
_feed_cache: ContextVar[dict | None] = ContextVar("ucb_feed_catalog", default=None)


@contextmanager
def feed_snapshot():
    """All campuses in one publish share the first catalog read, even when
    detail enrichment between campuses takes longer than the polling TTL."""
    token = _feed_cache.set({})
    try:
        yield
    finally:
        _feed_cache.reset(token)


def _text(node, selector):
    el = node.select_one(selector)
    return clean(el.get_text(" ", strip=True)) if el else ""


def _start(dates: str, schedule: str, city: str, today: date) -> str | None:
    # The register page gives a month/day, sometimes including a year. It
    # lists upcoming classes and can still show yesterday near midnight.
    match = re.match(r"([A-Za-z]+) (\d{1,2})(?:,? (\d{4}))?\b", dates)
    if not match:
        return None
    month, day, year = match.groups()
    for candidate in ([int(year)] if year else [today.year - 1, today.year, today.year + 1]):
        try:
            first = datetime.strptime(f"{month[:3]} {day} {candidate}", "%b %d %Y")
        except ValueError:
            continue
        if year or first.date() >= today - timedelta(days=7):
            break
    else:
        return None
    clock = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?", schedule, re.I)
    if not clock:
        return first.date().isoformat()
    hour, minute, meridiem = clock.groups()
    if not 1 <= int(hour) <= 12 or int(minute or 0) >= 60:
        return first.date().isoformat()
    first = first.replace(hour=int(hour) % 12 + (12 if meridiem.lower() == "p" else 0),
                          minute=int(minute or 0))
    # The app interprets naive Online times as Eastern. UCB often publishes
    # online times in Pacific time; the displayed schedule retains its label.
    if city == "Online":
        zone = re.search(r"\b(PT|PDT|PST|ET|EDT|EST)\b", schedule, re.I)
        if zone and zone[1].upper().startswith("P"):
            first = first.replace(tzinfo=ZoneInfo("America/Los_Angeles")).astimezone(CITY_TZ[city])
            first = first.replace(tzinfo=None)
    return first.isoformat()


def _parse_catalog(html: str) -> list[tuple[dict, list[str], bool]]:
    soup = BeautifulSoup(html, "lxml")
    rows = soup.select("tr.ucb-cl-run")
    total = re.fullmatch(r"Showing ([\d,]+) class(?:es)?", _text(soup, ".ucb-cl-count"), re.I)
    if not rows or not total or len(rows) != int(total[1].replace(",", "")):
        raise ValueError(f"Incomplete UCB registration catalog ({len(rows)} section rows)")
    sessions = []
    seen = set()
    for row in rows:
        where = row.select_one('[data-label="Where"] .ucb-cl-run-value')
        if not where:
            raise ValueError("UCB section is missing its location")
        city = _text(where, ".ucb-cl-run-sub") or clean(where.get_text(" ", strip=True))
        school = _SCHOOLS.get(city)
        if not school:
            continue  # UCB also publishes classes in Austin, Pittsburgh, etc.
        link = row.select_one('[data-label="Status"] a[href]')
        url = urlsplit(urljoin(CATALOG_URL, link["href"])) if link else None
        path = _SECTION_PATH.fullmatch(url.path) if url and url.netloc == "ucbcomedy.com" else None
        section = row.find_parent("section", class_="ucb-cl-sub")
        group = row.find_parent("article", class_="ucb-cl-course")
        title = _text(section, ".ucb-cl-sub-title") if section else ""
        if not path or url.scheme != "https" or not title or row.get("data-open") not in ("0", "1"):
            raise ValueError(f"Incomplete UCB section for {title!r} in {city}")
        slug, number = path.groups()
        key = f"{slug}/{number}"
        if key in seen:
            raise ValueError(f"Duplicate UCB section {key}")
        seen.add(key)
        session_id = _LEGACY_IDS.get(key, f"section-{slug}-{number}")
        dates = _text(row, '[data-label="Starts"]')
        pattern = _text(row, '[data-label="Schedule"]')
        # The in-person meeting calendar is venue-local. UCB's LA stand-up
        # section, for example, says 7 PM PST in its meetings but has a stray
        # “ET” in the listing. Keep the venue clock and omit a conflicting
        # label. Online listings explicitly use both Eastern and Pacific.
        if city == "Los Angeles":
            pattern = re.sub(r"\s+E(?:[DS])?T\b", "", pattern, flags=re.I)
        elif city == "New York":
            pattern = re.sub(r"\s+P(?:[DS])?T\b", "", pattern, flags=re.I)
        instructor = _text(row, '[data-label="Instructor"] .ucb-cl-run-value')
        item = make_class(
            id=f"{school}/{session_id}", source=school, org="UCB", city=city,
            title=title, url="https://ucbcomedy.com" + path[0],
            instructor="Teacher TBD" if instructor == "UCBclasses" else instructor,
            schedule=" · ".join(filter(None, (pattern, dates))),
            start=_start(dates, pattern, city, local_today(city)),
            level=_text(group, ".ucb-cl-course-title") if group else "",
            price=_text(row, '[data-label="Price"]'),
            location=clean(where.get_text(", ", strip=True)), is_full=row["data-open"] == "0",
        )
        listed_categories = row.get("data-cat", "").split()
        categories = listed_categories or list(_GROUP_CATEGORIES.get(item["level"], ()))
        tags = categories + row.get("data-freq", "").split()
        sessions.append((item, tags, not listed_categories))
    if not sessions:
        raise ValueError("UCB registration catalog has no supported locations")
    return sessions


def catalog() -> list[tuple[dict, list[str], bool]]:
    global _memo
    scope = _feed_cache.get()
    cached = None
    if scope is not None:
        cached = scope.get("catalog")
    elif _memo and time.monotonic() - _memo[0] < _MEMO_TTL:
        cached = _memo[1]
    if isinstance(cached, Exception):
        raise RuntimeError(f"UCB catalog failed earlier this run: {cached}") from cached
    if cached is not None:
        return cached
    try:
        # UCB's bare page is served from a shared WordPress page cache. A
        # stable query gets the same public listing with current seat counts.
        sessions = _parse_catalog(fetch_html(CATALOG_URL + "?improv_catalog=1"))
    except Exception as exc:
        sessions = exc
    _memo = (time.monotonic(), sessions)
    if scope is not None:
        scope["catalog"] = sessions
    if isinstance(sessions, Exception):
        raise sessions
    return sessions


def section_category_tags(url: str) -> list[str]:
    """Read explicit subject labels from a new section whose listing omits them."""
    try:
        soup = BeautifulSoup(fetch_html(url), "lxml")
    except Exception as exc:  # optional detail must not delay the alert past this scan
        log.warning("UCB section categories unavailable at %s: %r", url, exc)
        return []
    tagline = _text(soup, ".ucb-class-band__tagline")
    label = re.fullmatch(r"Category:\s*(.+)", tagline, re.I)
    if not label:
        return []
    return [tag for subject in label[1].split("/") for tag in _GROUP_CATEGORIES.get(subject.strip(), ())]


def class_detail(url: str) -> dict | None:
    soup = BeautifulSoup(fetch_html(url), "lxml")
    # A redirect to the generic course page does not identify this section.
    if not soup.select_one(".ucb-class-band__title"):
        return None
    about = soup.select_one(".ucb-class-about__body")
    return {"description": block_text(about) if about else ""}


def _for_school(source: str) -> list[dict]:
    # Feed enrichment mutates its rows; keep the common listing read-only.
    return [item.copy() for item, _, _ in catalog() if item["source"] == source]


def fetch_ny() -> list[dict]:
    return _for_school("ucb_ny")


def fetch_la() -> list[dict]:
    return _for_school("ucb_la")


def fetch_online() -> list[dict]:
    return _for_school("ucb_online")

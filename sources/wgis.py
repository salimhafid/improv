"""World's Greatest Improv School (WGIS) — New York & Los Angeles.

Shows come from the shared Crowdwork feed (slug "wgis"), split into NY/LA by the
event's `timezone` name (UTC offset as fallback). Classes are scraped from the
static /nycclasses and /laclasses pages (rows of div.row.mb-1 linking to
/workshop/view/<id>).
"""
from __future__ import annotations

import re
from datetime import date, datetime

from bs4 import BeautifulSoup
from dateutil import parser as dateparser

from common import clean, fetch_html, local_today, make_class

from . import crowdwork

BASE = "https://www.wgimprovschool.com"
ORG = "WGIS"
_WORKSHOP_RE = re.compile(r"/workshop/view/(\d+)")


# ---- Shows (Crowdwork, split by timezone) ----------------------------------

def fetch_shows_ny() -> list[dict]:
    return crowdwork.fetch_shows("wgis", "wgis_ny", ORG, "New York", city_from_tz=True)


def fetch_shows_la() -> list[dict]:
    return crowdwork.fetch_shows("wgis", "wgis_la", ORG, "Los Angeles", city_from_tz=True)


# ---- Classes (static HTML) -------------------------------------------------

# A calendar date needs a month token and a day number ("Thu Jul 9 7pm");
# "Mondays 7pm" / "Sat 7pm" carry no date and must stay undated rather than
# parse to dateutil's January default.
_MONTH_DAY_RE = re.compile(
    r"\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|"
    r"Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b\.?\s+\d{1,2}(?:st|nd|rd|th)?\b", re.I)
_YEAR_RE = re.compile(r"\b(?:19|20)\d{2}\b")
# Section headings whose rows are already underway ("Currently Running" on
# both class pages): their dates are past starts, kept undated like Magnet's
# in-session sections instead of being rolled into next year.
_IN_SESSION_RE = re.compile(r"currently running|in session", re.I)
# Never roll a date this far forward: a start that lands more than ~9 months
# out is an in-session course whose section heading we failed to recognise.
_MAX_ROLL_AHEAD_DAYS = 270


def _parse_when_start(when: str, today: date | None = None):
    """Start datetime from 'Thu Jul 9 7pm (2 hrs)'. The strings carry no year,
    so around New Year a January workshop must not land 11 months in the past:
    anything more than ~45 days behind today rolls into next year, unless the
    rolled date would sit more than ~9 months out (then it is an in-session
    course, published undated). Strings with an explicit year are taken as
    written; strings without a month + day are undated."""
    today = today or local_today("New York")
    head = when.split("(")[0].strip()
    if not _MONTH_DAY_RE.search(head):
        return None
    try:
        dt = dateparser.parse(head, fuzzy=True, default=datetime(today.year, 1, 1))
    except (ValueError, OverflowError, TypeError):
        return None
    if _YEAR_RE.search(head):
        return dt.isoformat()
    if (today - dt.date()).days > 45:
        try:
            dt = dt.replace(year=dt.year + 1)
        except ValueError:  # Feb 29 in a non-leap year
            return None
        if (dt.date() - today).days > _MAX_ROLL_AHEAD_DAYS:
            return None
    elif (dt.date() - today).days > 200:
        # Mirror case: a December class viewed in January parses ~11 months in
        # the FUTURE (default year is the new year) — roll back to last year so
        # an in-session class isn't published as next December's.
        try:
            dt = dt.replace(year=dt.year - 1)
        except ValueError:
            return None
    return dt.isoformat()


def _parse_classes(html: str, source: str, city: str, today: date | None = None) -> list[dict]:
    today = today or local_today(city)
    soup = BeautifulSoup(html, "html.parser")
    out: list[dict] = []
    for row in soup.select("div.row.mb-1"):
        cols = row.find_all("div", class_="col-3", recursive=False)
        if len(cols) < 4:
            continue
        title_cell, instr_cell, date_cell, price_cell = cols[:4]
        link = title_cell.find("a", href=_WORKSHOP_RE)
        if not link:
            continue
        wid = _WORKSHOP_RE.search(link.get("href", "")).group(1)
        title = clean(link.get_text())
        if not title:
            continue
        cell_text = title_cell.get_text(" ", strip=True).lower()
        is_full = any(w in cell_text for w in ("sold out", "sold-out", "wait list", "waitlist"))
        when = clean(date_cell.get_text(" "))
        h4 = row.find_previous("h4")
        level = clean(h4.get_text(" ")) if h4 else "Classes"
        out.append(make_class(
            id=f"{source}/{wid}",
            title=title,
            url=f"{BASE}/workshop/view/{wid}",
            instructor=clean(instr_cell.get_text(" ")),
            schedule=when,
            start=None if _IN_SESSION_RE.search(level) else _parse_when_start(when, today),
            price=clean(price_cell.get_text(" ")),
            level=level,
            is_full=is_full,
            source=source, org=ORG, city=city,
        ))
    return out


def fetch_classes_ny() -> list[dict]:
    return _parse_classes(fetch_html(f"{BASE}/nycclasses"), "wgis_ny", "New York")


def fetch_classes_la() -> list[dict]:
    return _parse_classes(fetch_html(f"{BASE}/laclasses"), "wgis_la", "Los Angeles")

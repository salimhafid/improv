"""World's Greatest Improv School (WGIS) — New York & Los Angeles.

Shows come from the shared Crowdwork feed (slug "wgis"), split into NY/LA by the
event's `timezone` name (UTC offset as fallback). Classes are scraped from the
static /nycclasses and /laclasses pages (rows of div.row.mb-1 linking to
/workshop/view/<id>). Each class's own page adds what the listing lacks:
the description, the room and address, and every session (class_detail).
"""
from __future__ import annotations

import re
from datetime import date, datetime

from bs4 import BeautifulSoup
from dateutil import parser as dateparser

from common import block_text, clean, fetch_html, local_today, make_class

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


# ---- Class detail page (/workshop/view/<id>) -------------------------------
#
#   <div id='class_description'><p><b>Class Description:</b></p><p>copy</p>...<hr></div>
#   <p>6 classes, 1 show<br>Sun Oct 4 12pm-3pm (LA)<br>...<br>Show: ...<br><br>$240 USD<br>Class size: 14</p>
#   <p><b>Location:</b><br>WGIS Space<br>1615 N. Vermont Ave.<br>LA CA 90027<br>directions</p>
#
# followed by the teacher's photo and biography and the site's policies, all
# outside these three elements. An unknown id answers with the campus chooser
# page, which has no #class_description.

_COUNT_RE = re.compile(r"^\d+\s+class", re.I)
_SESSION_RE = re.compile(
    r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\.?\s+([A-Z][a-z]{2,8})\.?\s+(\d{1,2})(?:,\s*(\d{4}))?"
    r"\s+(\d[\d:]*[ap]m(?:-\d[\d:]*[ap]m)?)(?:\s+\((\w+)\))?", re.I)
_LOCATION_LABEL_RE = re.compile(r"^\s*Location:?\s*$", re.I)
_SOFT_SPACE_RE = re.compile(r"[\r\n\xa0]")
_CITY_LINE_RE = re.compile(r"^(.*?),?\s+([A-Z]{2})\s+(\d{5})(?:-\d{4})?$")
_CITY_NAMES = {"la": "Los Angeles", "nyc": "New York"}
_ZONES = {"la": "PT", "pst": "PT", "pdt": "PT", "nyc": "ET", "est": "ET", "edt": "ET"}
_WEEKDAYS = {"mon": "Mondays", "tue": "Tuesdays", "wed": "Wednesdays", "thu": "Thursdays",
             "fri": "Fridays", "sat": "Saturdays", "sun": "Sundays"}


def _lines(el) -> list[str]:
    """An element's text as its <br>-separated lines, blanks dropped."""
    return [line for line in (clean(part) for part in el.get_text("\n").split("\n")) if line]


def _detail_description(box) -> str:
    for label in box.find_all("b"):
        if clean(label.get_text()).lower().startswith("class description"):
            label.decompose()
            break
    # The copy puts a source newline after each <br>; left in, every list
    # line would come out as its own paragraph. Non-breaking spaces go too.
    for text in box.find_all(string=True):
        if _SOFT_SPACE_RE.search(text):
            text.replace_with(_SOFT_SPACE_RE.sub(" ", text))
    return block_text(box)


def _detail_location(box) -> str:
    # Only the paragraphs after the description: a "Location:" heading inside
    # the copy itself is not the address block.
    label = next((b for p in box.find_next_siblings("p")
                  for b in p.find_all("b", string=_LOCATION_LABEL_RE)), None)
    if label is None:
        return ""
    lines = _lines(label.parent)[1:]            # [0] is the label itself
    if not lines:
        return ""
    if lines[0].lower() == "online":
        return "Online"
    parts: list[str] = []
    for line in lines:
        m = _CITY_LINE_RE.match(line)
        if m:                                   # "LA CA 90027": directions follow, not address
            city = _CITY_NAMES.get(m.group(1).lower(), m.group(1))
            parts.append(f"{city}, {m.group(2)} {m.group(3)}")
            break
        parts.append(line.rstrip(","))
    return ", ".join(parts)


def _detail_schedule(box) -> str:
    """One line from the session list: 'Sundays 12pm-3pm PT · Oct 4 - Nov 15 ·
    6 classes' (a single session keeps its date: 'Thu Dec 3 7pm-9pm PT · 1
    class'). "" when the list is missing or not in the expected shape."""
    block = next((p for p in box.find_next_siblings("p") if _COUNT_RE.match(clean(p.get_text(" ")))), None)
    if block is None:
        return ""
    lines = _lines(block)
    sessions = [m for m in (_SESSION_RE.match(line) for line in lines) if m]   # "Show: ..." lines don't match
    if not sessions:
        return ""
    first, last = sessions[0], sessions[-1]
    zone = (first.group(6) or "").lower()
    zone = _ZONES.get(zone, zone.upper())
    times = {m.group(5).lower() for m in sessions}
    # Sessions at different hours: no single time to state, so no zone either.
    hours = f"{times.pop()} {zone}".strip() if len(times) == 1 else ""

    def day(m) -> str:
        return f"{m.group(2)} {m.group(3)}" + (f", {m.group(4)}" if m.group(4) else "")

    if len(sessions) == 1:
        return " \u00b7 ".join(x for x in (f"{first.group(1)} {day(first)} {hours}".strip(), lines[0]) if x)
    days: list[str] = []
    for m in sessions:
        if m.group(1).title() not in days:
            days.append(m.group(1).title())
    pattern = _WEEKDAYS[days[0].lower()] if len(days) == 1 else "/".join(days)
    start = f"{first.group(2)} {first.group(3)}" if first.group(4) == last.group(4) else day(first)
    return " \u00b7 ".join((f"{pattern} {hours}".strip(), f"{start} - {day(last)}", lines[0]))


def _parse_class_detail(html: str) -> dict | None:
    soup = BeautifulSoup(html, "html.parser")
    box = soup.find(id="class_description")
    if box is None:
        return None
    # Schedule first: _detail_description strips the label out of `box`.
    schedule = _detail_schedule(box)
    return {
        "description": _detail_description(box),
        "location": _detail_location(box),
        "schedule": schedule,
    }


def class_detail(url: str) -> dict | None:
    """Description, location and full schedule from a class's own page; None
    when it could not be fetched or is not a class page. The teacher photo
    (the page's only image), biography and site policies are left out."""
    try:
        html = fetch_html(url)
    except RuntimeError:
        return None
    return _parse_class_detail(html)

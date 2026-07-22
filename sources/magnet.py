"""Magnet Theater (NYC) adapter.

Magnet's WordPress month-calendar (magnettheater.com/calendar/month/) is a table
grid: each day cell is a <td> with <strong class="date">N</strong> and one
<div class="an-event"> per show (a `.time` label like "6:00pm - $5", a title in
<p class="summary">, and a /show/<id> link). Padding cells have a blank date, so
only cells with a numeric day are real. We parse the current month plus the next
two to cover everything upcoming.
"""
from __future__ import annotations

import re
from datetime import date, datetime
from urllib.parse import urljoin

from bs4 import BeautifulSoup
from dateutil import parser as dateparser

from common import clean, fetch_html, make_class, make_show, safe_url

CAL = "https://magnettheater.com/calendar/month/?date=%04d-%02d-01"
CLASS_INDEX = "https://magnettheater.com/class/all-classes-in-session/"
_TIME = re.compile(r"\d{1,2}:\d{2}\s*[ap]m", re.I)
MONTHS_AHEAD = 3


def _months(today: date, n: int) -> list[tuple[int, int]]:
    y, m, out = today.year, today.month, []
    for _ in range(n):
        out.append((y, m))
        m += 1
        if m > 12:
            m, y = 1, y + 1
    return out


def _parse_month(html: str, year: int, month: int) -> list[dict]:
    soup = BeautifulSoup(html, "lxml")
    shows: list[dict] = []
    for td in soup.select("td"):
        day_el = td.select_one("strong.date")
        if not day_el:
            continue
        day_txt = day_el.get_text(strip=True)
        if not day_txt.isdigit():
            continue
        try:
            day = date(year, month, int(day_txt))
        except ValueError:
            continue

        for ev in td.select("div.an-event"):
            a = ev.select_one("a[href*='/show/']")
            if not a:
                continue
            title = clean((ev.select_one("p.summary") or a).get_text())
            url = safe_url(a.get("href"))
            if not title or not url:
                continue

            time_el = ev.select_one(".time")
            time_text = clean(time_el.get_text()) if time_el else ""
            tm = _TIME.search(time_text)
            dt = None
            if tm:
                try:
                    dt = dateparser.parse(f"{day.isoformat()} {tm.group(0)}")
                except (ValueError, OverflowError):
                    dt = None
            if dt:
                start = dt.replace(microsecond=0).isoformat()
                date_raw = dt.strftime("%A, %B %-d @ %-I:%M %p")
            else:
                start = day.isoformat()
                date_raw = day.strftime("%A, %B %-d")

            shows.append(make_show(
                title=title,
                url=url,
                slug=url.rstrip("/").split("/")[-1],
                date_raw=date_raw,
                start=start,
                has_time=dt is not None,
                venue="Magnet Theater",
                venues=["Magnet Theater"],
                comedy_types=[],
                image=None,
                excerpt="",
                is_free=("free" in time_text.lower()),
                source="magnet",
                org="Magnet Theater",
                city="New York",
            ))
    return shows


def detail(url: str) -> tuple[str, str, str | None, list[dict]]:
    """Fetch a Magnet show page → (description, cast, hero image, structured
    cast). Cast isn't structured on Magnet, so only description + og:image are
    returned. The calendar grid has no images at all, so the og:image here is
    each show's only artwork."""
    try:
        soup = BeautifulSoup(fetch_html(url), "lxml")
    except RuntimeError:
        return "", "", None, []
    el = soup.select_one("#content") or soup.select_one(".summary") or soup
    text = re.sub(r"^\s*About the Show\s*", "", clean(el.get_text(" ")))
    og = soup.select_one('meta[property="og:image"]')
    image = safe_url(og.get("content")) if og else None
    return text[:2000], "", image, []


def fetch(today: date | None = None) -> list[dict]:
    today = today or date.today()
    shows: list[dict] = []
    errors = 0
    for year, month in _months(today, MONTHS_AHEAD):
        try:
            html = fetch_html(CAL % (year, month))
            shows.extend(_parse_month(html, year, month))
        except RuntimeError:
            errors += 1
    if not shows and errors:
        raise RuntimeError("magnet: all month fetches failed")
    return shows


# MARK: Classes

def _class_discipline(ctype: str) -> str:
    """Drop a level indicator ('Level Two', 'L1', '… Level Two Intensive') so
    sections group by discipline (Improv, Musical Improv, Sketch Writing, …)."""
    return re.sub(r"\s*(?:\bLevel\b.*|\bL\d.*)$", "", ctype, flags=re.I).strip() or ctype


def _infer_date(txt: str, today: date):
    """Parse 'June 28th' (no year) to the nearest occurrence around `today`, so we
    can tell whether a section has already ended."""
    if not txt:
        return None
    try:
        base = dateparser.parse(txt, default=datetime(today.year, 1, 1)).date()
    except (ValueError, OverflowError, TypeError):
        return None
    best = None
    for y in (today.year - 1, today.year, today.year + 1):
        try:
            cand = base.replace(year=y)
        except ValueError:
            continue
        if best is None or abs((cand - today).days) < abs((best - today).days):
            best = cand
    return best


# Confirmed per-discipline listing slugs, used only if nav discovery finds
# nothing (the nav and this list both change rarely).
_KNOWN_DISCIPLINES = [
    "improv-level-one", "improv-level-two", "improv-level-three",
    "advanced-improv-level-one", "advanced-improv-level-two",
    "musical-improv-one", "musical-improv-two", "musical-improv-three",
    "sketch-writing-one", "sketch-writing-two", "sketch-writing-three",
    "storytelling",
]
_DISCIPLINE_URL = re.compile(r"https://magnettheater\.com/class/([a-z0-9-]+)/?$")
_MAX_DISCIPLINE_PAGES = 20


def _discipline_urls(soup: BeautifulSoup) -> list[str]:
    """Per-discipline listing pages (/class/<slug>/) from the index page's nav.
    These carry upcoming sections open for enrollment, which the in-session
    index never shows."""
    urls: list[str] = []
    seen: set[str] = set()
    for a in soup.select("a[href*='/class/']"):
        href = urljoin(CLASS_INDEX, a.get("href", "")).split("?")[0].split("#")[0]
        m = _DISCIPLINE_URL.match(href.rstrip("/") if href.endswith("/") else href)
        if not m:
            continue
        slug = m.group(1)
        if slug == "all-classes-in-session" or slug in seen:
            continue
        seen.add(slug)
        urls.append(f"https://magnettheater.com/class/{slug}/")
    if not urls:
        urls = [f"https://magnettheater.com/class/{s}/" for s in _KNOWN_DISCIPLINES]
    return urls[:_MAX_DISCIPLINE_PAGES]


def fetch_classes(today: date | None = None) -> list[dict]:
    """Class sections from the 'All Classes In Session' index plus every
    per-discipline /class/<slug>/ page — upcoming sections open for enrollment
    only appear on the latter. All pages share the div.class-holder markup
    (instructor + type + schedule + dates + status); sections dedupe by their
    WordPress id. No price is published anywhere, so price stays blank.
    Sections whose run has already ended are dropped."""
    today = today or date.today()
    index_soup = BeautifulSoup(fetch_html(CLASS_INDEX), "lxml")
    out: list[dict] = []
    seen_ids: set[str] = set()
    _collect_cards(index_soup, today, out, seen_ids)
    for url in _discipline_urls(index_soup):
        try:
            soup = BeautifulSoup(fetch_html(url), "lxml")
        except RuntimeError:
            continue    # one dead discipline page must not sink the source
        _collect_cards(soup, today, out, seen_ids)
    return out


def _collect_cards(soup: BeautifulSoup, today: date,
                   out: list[dict], seen_ids: set[str]) -> None:
    for card in soup.select("div.class-holder"):
        det = card.select_one("div.details")
        type_a = det.select_one("strong a") if det else None
        ctype = clean(type_a.get_text()) if type_a else ""
        if not ctype:
            continue
        href = type_a.get("href", "")
        cid = re.sub(r"\D", "", href) or href
        if cid in seen_ids:
            continue    # same section listed on both the index and its discipline page
        # The href is a bare relative WordPress id; resolve it against the index
        # URL (a fabricated /class/<id> 404s/redirects to a generic page).
        url = urljoin(CLASS_INDEX, href)
        if not url.endswith("/"):
            url += "/"

        names = []
        for a in card.select("div.instructor a"):
            nm = clean(a.get_text())
            if nm and nm not in names:
                names.append(nm)
        instructor = ", ".join(names)

        # clean() each line so the schedule-line lookup is whitespace-insensitive.
        lines = [clean(l) for l in det.get_text("\n").split("\n") if clean(l)]
        def _after(label: str) -> str:
            for j, l in enumerate(lines):
                if l.lower().startswith(label) and j + 1 < len(lines):
                    return lines[j + 1]
            return ""
        # schedule = the line right after the type, before "Starts:"
        sched = ""
        if ctype in lines:
            i = lines.index(ctype)
            if i + 1 < len(lines) and not lines[i + 1].lower().startswith("start"):
                sched = lines[i + 1]
        start_txt, end_txt = _after("start"), _after("end")

        # Drop sections whose run has already ended.
        end_date = _infer_date(end_txt, today)
        if end_date and end_date < today:
            continue

        date_range = " – ".join(x for x in (start_txt, end_txt) if x)
        schedule = f"{sched} · {date_range}" if sched and date_range else (sched or date_range)
        status = lines[-1].lower() if lines else ""
        is_full = any(w in status for w in ("full", "sold", "wait"))

        # Upcoming sections get a real start so the app can sort/filter by it;
        # in-session sections have past starts and stay undated (always shown).
        start_date = _infer_date(start_txt, today)
        start = start_date.isoformat() if start_date and start_date >= today else None

        seen_ids.add(cid)
        out.append(make_class(
            id=f"magnet/{cid}",
            title=ctype,
            url=safe_url(url),
            instructor=instructor,
            schedule=schedule,
            start=start,
            price="",
            level=_class_discipline(ctype),
            description="",
            is_full=is_full,
            source="magnet", org="Magnet Theater", city="New York",
        ))

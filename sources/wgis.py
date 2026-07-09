"""World's Greatest Improv School (WGIS) — New York & Los Angeles.

Shows come from the shared Crowdwork feed (slug "wgis"), split into NY/LA by the
event's timezone offset. Classes are scraped from the static /nycclasses and
/laclasses pages (rows of div.row.mb-1 linking to /workshop/view/<id>).
"""
from __future__ import annotations

import re

from bs4 import BeautifulSoup
from dateutil import parser as dateparser

from common import clean, fetch_html, make_class

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

def _parse_when_start(when: str):
    head = when.split("(")[0].strip()  # "Thu Jul 9 7pm"
    try:
        return dateparser.parse(head, fuzzy=True).isoformat()
    except (ValueError, OverflowError, TypeError):
        return None


def _parse_classes(html: str, source: str, city: str) -> list[dict]:
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
        is_full = "sold out" in cell_text or "wait list" in cell_text
        when = clean(date_cell.get_text(" "))
        h4 = row.find_previous("h4")
        out.append(make_class(
            id=f"{source}/{wid}",
            title=title,
            url=f"{BASE}/workshop/view/{wid}",
            instructor=clean(instr_cell.get_text(" ")),
            schedule=when,
            start=_parse_when_start(when),
            price=clean(price_cell.get_text(" ")),
            level=clean(h4.get_text(" ")) if h4 else "Classes",
            is_full=is_full,
            source=source, org=ORG, city=city,
        ))
    return out


def fetch_classes_ny() -> list[dict]:
    return _parse_classes(fetch_html(f"{BASE}/nycclasses"), "wgis_ny", "New York")


def fetch_classes_la() -> list[dict]:
    return _parse_classes(fetch_html(f"{BASE}/laclasses"), "wgis_la", "Los Angeles")

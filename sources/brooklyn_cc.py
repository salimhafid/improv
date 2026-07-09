"""Brooklyn Comedy Collective adapter — Squarespace Events collection, exposed
cleanly as JSON via the `?format=json` view."""
from __future__ import annotations

import re
from datetime import datetime
from zoneinfo import ZoneInfo

from bs4 import BeautifulSoup

from common import clean, fetch_html, fetch_json, make_class, make_show, safe_url, strip_html

URL = "https://www.brooklyncc.com/show-schedule?format=json"
BASE = "https://www.brooklyncc.com"
# Classes: the marketing page lists which class-registration products are
# currently offered; the products collection carries the structured price/body.
CLASSES_PAGE = "https://www.brooklyncc.com/comedy-classes"
REG_COLLECTION = "https://www.brooklyncc.com/class-registration?format=json"
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

        shows.append(make_show(
            title=title,
            url=url,
            slug=slug,
            date_raw=date_raw,
            start=start_iso,
            end=end_iso,
            has_time=start_dt is not None,
            venue="Brooklyn Comedy Collective",
            venues=["Brooklyn Comedy Collective"],
            comedy_types=[clean(c) for c in (it.get("categories") or [])][:3],
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

def _variant_price(it: dict) -> str:
    """Squarespace stores the real price on the product's first paid variant;
    the top-level priceMoney is often 0.00."""
    for v in (it.get("variants") or []):
        val = ((v.get("priceMoney") or {}).get("value")) or ""
        if val and val not in ("0", "0.00"):
            return f"${val}"
    val = (it.get("priceMoney") or {}).get("value") or ""
    return f"${val}" if val and val not in ("0", "0.00") else ""


def _is_full(it: dict) -> bool:
    """Sold out when every (limited) variant is out of stock — read from the
    product's structured stock rather than fragile page badge text."""
    variants = it.get("variants") or []
    if not variants:
        return False
    return all((not v.get("unlimited")) and (v.get("qtyInStock") or 0) <= 0 for v in variants)


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
    m = re.search(r"w/\s*(.+?)\s*(?:\(|$)", title)
    return clean(m.group(1)) if m else ""


def _class_schedule(title: str) -> str:
    return " · ".join(clean(p) for p in re.findall(r"\(([^)]+)\)", title) if clean(p))


def fetch_classes() -> list[dict]:
    # 1) Which class-registration products are currently offered (the marketing
    #    page lists the live ones; the collection also holds archived products).
    soup = BeautifulSoup(fetch_html(CLASSES_PAGE), "lxml")
    current: set[str] = set()
    for a in soup.select('a[href^="/class-registration/"]'):
        href = a.get("href", "").split("?")[0]
        if href and "gift" not in href:
            current.add(href)

    # 2) Structured title/price/body/stock keyed by product url.
    data = fetch_json(REG_COLLECTION)
    items = {it.get("fullUrl"): it for it in (data.get("items") or [])}

    out: list[dict] = []
    for href in sorted(current):
        it = items.get(href)
        if not it:
            continue
        title = clean(it.get("title"))
        if not title:
            continue
        out.append(make_class(
            id=f"brooklyn_cc/{href.rstrip('/').split('/')[-1]}",
            title=title,
            url=safe_url(BASE + href),
            instructor=_class_instructor(title),
            schedule=_class_schedule(title),
            start=None,  # Squarespace products carry no structured date
            price=_variant_price(it),
            level=_class_level(title),
            description=strip_html(it.get("body")) or strip_html(it.get("excerpt")),
            is_full=_is_full(it),
            source="brooklyn_cc", org="Brooklyn Comedy Collective", city="New York",
        ))
    return out

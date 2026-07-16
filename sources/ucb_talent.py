"""UCB talent directory adapter.

The NY, LA, and teachers pages share the same WordPress "dt_team" grid
markup: each person is a `div.wf-cell` carrying `data-name`, a
`/people/<slug>/` profile link, a lazy-loaded headshot in `data-src`, and
category classes (`dt_team_category-dcm`, house-team names, …) on the inner
`.team-container`.

The DCM talent page is intentionally NOT fetched: it's a WP Grid Builder AJAX
grid whose /page/N/ URLs all serve the same first 30 people, so DCM membership
is derived from the `dt_team_category-dcm` class on the two static pages
instead (266 of the 450 NY performers carry it).
"""
from __future__ import annotations

import re

from bs4 import BeautifulSoup

from common import clean, fetch_html, safe_url

PAGES = [
    ("ny",       "https://ucbcomedy.com/talent/new-york/"),
    ("la",       "https://ucbcomedy.com/talent/los-angeles/"),
    ("teachers", "https://ucbcomedy.com/talent/teachers/"),
]

_SLUG = re.compile(r"/people/([^/]+)/?")


def bio(url: str) -> str:
    """Fetch a /people/<slug>/ profile page → bio text. Best-effort."""
    try:
        soup = BeautifulSoup(fetch_html(url), "lxml")
    except RuntimeError:
        return ""
    el = soup.select_one(".ucb-talent-individual__bio")
    return clean(el.get_text(" "))[:1500] if el else ""


def fetch_page(url: str) -> list[dict]:
    """One dt_team talent page → [{name, slug, url, image, dcm}]."""
    soup = BeautifulSoup(fetch_html(url), "lxml")
    people: list[dict] = []
    for cell in soup.select("div.wf-cell[data-name]"):
        name = clean(cell.get("data-name", ""))
        link = cell.select_one("a[href*='/people/']")
        if not name or not link:
            continue
        href = safe_url(link.get("href"))
        m = _SLUG.search(href or "")
        if not m:
            continue
        img_el = cell.select_one("img[data-src]") or cell.select_one("img[src]")
        raw = (img_el.get("data-src") or img_el.get("src") or "") if img_el else ""
        image = safe_url(raw) if raw.startswith("http") else None

        container = cell.select_one(".team-container")
        classes = " ".join((container.get("class") if container else cell.get("class")) or [])
        people.append({
            "name": name,
            "slug": m.group(1),
            "url": href,
            "image": image,
            "dcm": "dt_team_category-dcm" in classes,
        })
    if not people:
        raise RuntimeError(f"ucb_talent: no people parsed from {url}")
    return people

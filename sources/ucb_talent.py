"""UCB talent directory adapter.

The NY, LA, and teachers pages share the same WordPress "dt_team" grid
markup: each person is a `div.wf-cell` carrying `data-name`, a
`/people/<slug>/` profile link, a lazy-loaded headshot in `data-src`, and
category classes (`dt_team_category-dcm`, house-team names, …) on the inner
`.team-container`.

The DCM talent page is a WP Grid Builder AJAX grid (its /page/N/ URLs all
serve the same first 30 people), so the full ~1,200-person roster is paged
through the grid's own load-more endpoint: POST `/?wpgb-ajax=refresh&
_load_more=<offset>` with a `wpgb` form field carrying the grid config —
captured from the live page's XHR traffic. The `dt_team_category-dcm` class
on the static pages still contributes dcm tags as a bonus.
"""
from __future__ import annotations

import json
import re
from concurrent.futures import ThreadPoolExecutor

from bs4 import BeautifulSoup

from common import clean, fetch_html, safe_url

PAGES = [
    ("ny",       "https://ucbcomedy.com/talent/new-york/"),
    ("la",       "https://ucbcomedy.com/talent/los-angeles/"),
    ("teachers", "https://ucbcomedy.com/talent/teachers/"),
]

_SLUG = re.compile(r"/people/([^/]+)/?")


_DCM_GRID_CONFIG = json.dumps({
    "main_query": [], "permalink": "https://ucbcomedy.com/talent/dcm-talent/",
    "facets": [2, 4, 5, 11, 13], "lang": "", "id": "team_grid_f82f7fb1",
    "is_template": True,
})
_DCM_ENDPOINT = "https://ucbcomedy.com/?wpgb-ajax=refresh&_load_more={offset}"
_DCM_BATCH = 12


def _dcm_batch(offset: int) -> tuple[list[dict], int]:
    """One load-more batch of the DCM grid → (people, reported total)."""
    from curl_cffi import requests as curl
    r = curl.post(_DCM_ENDPOINT.format(offset=offset),
                  data={"wpgb": _DCM_GRID_CONFIG}, impersonate="chrome", timeout=30)
    d = r.json()
    posts = (d.get("posts") or "").replace("\\/", "/")
    people = []
    for m in re.finditer(r'<a href="(https://ucbcomedy\.com/people/([^/"]+)/)"\s+aria-label="([^"]+)">\s*<img[^>]+src="([^"]+)"', posts):
        people.append({"name": clean(m.group(3)), "slug": m.group(2),
                       "url": m.group(1), "image": safe_url(m.group(4))})
    return people, int(d.get("total") or 0)


def fetch_dcm_roster() -> list[dict]:
    """The full DCM roster via the grid's load-more endpoint. The first batch
    reports the total, the rest are fetched in parallel."""
    first, total = _dcm_batch(0)
    if not first or not total:
        raise RuntimeError("ucb_talent: DCM roster endpoint returned nothing")
    offsets = list(range(len(first), total, _DCM_BATCH))
    with ThreadPoolExecutor(max_workers=8) as ex:
        batches = list(ex.map(lambda o: _dcm_batch(o)[0], offsets))
    seen: dict[str, dict] = {p["slug"]: p for p in first}
    for b in batches:
        for p in b:
            seen.setdefault(p["slug"], p)
    if len(seen) < total * 0.8:
        raise RuntimeError(f"ucb_talent: DCM roster incomplete ({len(seen)}/{total})")
    return list(seen.values())


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

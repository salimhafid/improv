"""UCB's public WordPress talent directory. Each published dt_team category
backs one roster. The REST collection supplies profile links, bios and
headshots and reports both the page count and total number of people. If
the REST collection is unavailable, the public directory's own A–Z and
Load more controls expose the roster with an independently verifiable total.
"""
from __future__ import annotations

import json
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlencode, urlsplit

from bs4 import BeautifulSoup

from common import clean, fetch_html, fetch_json, post_json, safe_url, strip_html

log = logging.getLogger("ucb.talent.source")

# Stable WordPress term IDs (ny-talent, la-talent, teachers, dcm).
GROUP_TERMS = {"ny": 31, "la": 21, "teachers": 22, "dcm": 270}
_COLLECTION = "https://ucbcomedy.com/wp-json/wp/v2/dt_team"


_LOCATION_FILTER = {"ny": "ny-talent", "la": "la-talent", "dcm": "dcm"}
_PUBLIC_SITE = "https://ucbcomedy.com"


class _CollectionUnavailable(RuntimeError):
    """A REST request failed before its roster could be validated."""


def _page(group: str, page: int) -> dict:
    query = urlencode({
        "dt_team_category": GROUP_TERMS[group], "per_page": 100,
        "orderby": "id", "order": "asc", "page": page, "_envelope": 1,
        "_fields": "slug,link,title.rendered,content.rendered,dt_team_category,yoast_head_json.og_image",
    })
    try:
        result = fetch_json(f"{_COLLECTION}?{query}")
    except RuntimeError as exc:
        raise _CollectionUnavailable(str(exc)) from exc
    if not isinstance(result, dict) or result.get("status") != 200 or not isinstance(result.get("body"), list):
        raise RuntimeError(f"ucb_talent: invalid {group} roster page {page}")
    return result


def _collection_group(group: str) -> list[dict]:
    first = _page(group, 1)
    headers = first["headers"]
    pages, total = int(headers["X-WP-TotalPages"]), int(headers["X-WP-Total"])
    if not (0 < total and pages == (total + 99) // 100):
        raise RuntimeError(f"ucb_talent: invalid {group} pagination ({total} people, {pages} pages)")
    rows = list(first["body"])
    with ThreadPoolExecutor(max_workers=4) as pool:
        for result in pool.map(lambda page: _page(group, page), range(2, pages + 1)):
            rows.extend(result["body"])

    people = {}
    for row in rows:
        slug, url = row["slug"], safe_url(row["link"])
        name = strip_html(row["title"]["rendered"])
        categories = row["dt_team_category"]
        if not (slug and url and name and GROUP_TERMS[group] in categories):
            raise RuntimeError(f"ucb_talent: invalid profile on {group} roster")
        images = (row.get("yoast_head_json") or {}).get("og_image") or []
        image = safe_url(images[0].get("url")) if images else None
        person = {"slug": slug, "name": name, "url": url, "image": image or None,
                  "dcm": GROUP_TERMS["dcm"] in categories}
        biography = strip_html((row.get("content") or {}).get("rendered"))[:1500]
        if biography:
            person.update(bio=biography, bio_done=True)
        people[slug] = person
    if len(people) != total:
        raise RuntimeError(f"ucb_talent: incomplete {group} roster ({len(people)}/{total})")
    return list(people.values())


def _directory_settings(group: str) -> dict:
    # NY, LA and DCM are filters on All Talent. Teachers is a separate grid.
    path = "teachers" if group == "teachers" else "all-talent"
    url = f"{_PUBLIC_SITE}/talent/{path}/"
    # The unfiltered All Talent URL redirects to Featured Talent's separate
    # grid. UCB's NY, LA and DCM navigation opens this filtered URL instead.
    entry_url = url + "?" + urlencode({"_filter_location_buttons": _LOCATION_FILTER[group]}) if group in _LOCATION_FILTER else url
    soup = BeautifulSoup(fetch_html(entry_url, retries=1), "lxml")
    grid = soup.select_one(".ucb-team-grid[data-options]")
    canonical = soup.select_one('link[rel="canonical"][href]')
    if not grid or not canonical or canonical["href"] != url:
        raise RuntimeError(f"ucb_talent: missing {path} directory")
    options = json.loads(grid["data-options"])
    grid_id = options.get("id")
    facets = [int(el["data-facet"]) for el in soup.select(".wpgb-facet[data-facet][data-grid]")
              if el["data-grid"] == grid_id]
    if not grid_id or not options.get("isTemplate") or not facets:
        raise RuntimeError(f"ucb_talent: incomplete {path} directory settings")
    return {"main_query": [], "permalink": url, "facets": facets, "lang": "",
            "id": grid_id, "is_template": True}


def _directory_page(group: str, settings: dict, offset: int, load_slug: str = "") -> tuple:
    params = {"wpgb-ajax": "refresh", "_filter_sort": "title_asc"}
    selection = [_LOCATION_FILTER[group]] if group in _LOCATION_FILTER else []
    if selection:
        params["_filter_location_buttons"] = selection[0]
    if offset:
        params["_" + load_slug] = str(offset)
    data = post_json(f"{_PUBLIC_SITE}/?{urlencode(params)}",
                     data={"wpgb": json.dumps(settings)}, retries=1)
    facets = {f["slug"]: f for f in data["facets"].values()}
    if (facets["filter_sort"]["selected"] != ["title_asc"]
            or facets["filter_location_buttons"]["selected"] != selection):
        raise RuntimeError(f"ucb_talent: directory did not apply {group} filters")
    more = next((f for f in facets.values() if f.get("type") == "load_more"), None)
    if not more or (offset and more["slug"] != load_slug) or more["settings"]["offset"] != offset:
        raise RuntimeError(f"ucb_talent: wrong directory offset for {group} at {offset}")
    total = int(data["total"])
    size = int(more["settings"]["number"])
    cards = BeautifulSoup(data["posts"], "lxml").select("article.ucb-team-card")
    if not (0 < size and 0 <= offset < total and len(cards) == min(size, total - offset)):
        raise RuntimeError(f"ucb_talent: incomplete {group} directory page at {offset}")

    people = []
    for card in cards:
        link = card.select_one(".wpgb-card-media-thumbnail a[href][aria-label]")
        name = clean(link.get("aria-label")) if link else ""
        url = urlsplit(link["href"]) if link else None
        profile = re.fullmatch(r"/people/([^/]+)/", url.path) if url else None
        if not (profile and name and url.scheme == "https" and url.netloc == "ucbcomedy.com"):
            raise RuntimeError(f"ucb_talent: invalid {group} directory profile at {offset}")
        photo = link.select_one("img[src]")
        image = safe_url(photo.get("src")) if photo else None
        people.append({"slug": profile[1], "name": name, "url": _PUBLIC_SITE + profile[0],
                       "image": image or None, "dcm": group == "dcm"})
    return people, total, size, more["slug"]


def _directory_group(group: str) -> list[dict]:
    settings = _directory_settings(group)
    people, total, size, load_slug = _directory_page(group, settings, 0)

    def load(offset):
        batch, reported_total, reported_size, _ = _directory_page(group, settings, offset, load_slug)
        if reported_total != total or reported_size != size:
            raise RuntimeError(f"ucb_talent: {group} directory changed during pagination")
        return batch

    # The A–Z sort makes offsets stable. Check every page and unique identity
    # before replacing a group; a repeated or truncated page retains old data.
    with ThreadPoolExecutor(max_workers=3) as pool:
        for batch in pool.map(load, range(size, total, size)):
            people.extend(batch)
    if len({p["slug"] for p in people}) != total:
        raise RuntimeError(f"ucb_talent: incomplete {group} directory (expected {total} unique profiles)")
    return people


def fetch_group(group: str) -> list[dict]:
    try:
        return _collection_group(group)
    except _CollectionUnavailable as collection_error:
        log.warning("UCB %s REST collection unavailable, reading the public directory: %s", group, collection_error)
        try:
            return _directory_group(group)
        except Exception as directory_error:
            raise RuntimeError(f"ucb_talent: {group} public directory failed: {directory_error}; "
                               f"REST collection failed: {collection_error}") from directory_error


def bio(url: str) -> str | None:
    """Profile fallback for people whose collection entry contains no bio."""
    try:
        soup = BeautifulSoup(fetch_html(url), "lxml")
    except RuntimeError:
        return None
    el = soup.select_one(".ucb-talent-individual__bio")
    return clean(el.get_text(" "))[:1500] if el else ""

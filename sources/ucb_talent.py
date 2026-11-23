"""UCB's public WordPress talent directory. Each published dt_team category
backs one roster. The REST collection supplies profile links, bios and
headshots and reports both the page count and total number of people.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlencode

from bs4 import BeautifulSoup

from common import clean, fetch_html, fetch_json, safe_url, strip_html

# Stable WordPress term IDs (ny-talent, la-talent, teachers, dcm).
GROUP_TERMS = {"ny": 31, "la": 21, "teachers": 22, "dcm": 270}
_COLLECTION = "https://ucbcomedy.com/wp-json/wp/v2/dt_team"


def _page(group: str, page: int) -> dict:
    query = urlencode({
        "dt_team_category": GROUP_TERMS[group], "per_page": 100,
        "orderby": "id", "order": "asc", "page": page, "_envelope": 1,
        "_fields": "slug,link,title.rendered,content.rendered,dt_team_category,yoast_head_json.og_image",
    })
    result = fetch_json(f"{_COLLECTION}?{query}")
    if not isinstance(result, dict) or result.get("status") != 200 or not isinstance(result.get("body"), list):
        raise RuntimeError(f"ucb_talent: invalid {group} roster page {page}")
    return result


def fetch_group(group: str) -> list[dict]:
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


def bio(url: str) -> str | None:
    """Profile fallback for people whose collection entry contains no bio."""
    try:
        soup = BeautifulSoup(fetch_html(url), "lxml")
    except RuntimeError:
        return None
    el = soup.select_one(".ucb-talent-individual__bio")
    return clean(el.get_text(" "))[:1500] if el else ""

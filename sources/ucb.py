"""UCB adapter — New York and Los Angeles share the same WordPress / WP Grid
Builder markup; only the URL (and city tag) differ."""
from __future__ import annotations

import re

from bs4 import BeautifulSoup

from common import clean, fetch_html, make_show, parse_datetime, safe_url

REGIONS = {
    "ny": ("ucb_ny", "UCB", "New York", "https://ucbcomedy.com/shows/new-york/"),
    "la": ("ucb_la", "UCB", "Los Angeles", "https://ucbcomedy.com/shows/los-angeles/"),
}


def _parse_cards(html: str, source: str, org: str, city: str) -> list[dict]:
    soup = BeautifulSoup(html, "lxml")
    shows: list[dict] = []
    for card in soup.select("article.wpgb-card"):
        title_el = card.select_one(".ucb-event-post-title a")
        if not title_el:
            continue
        title = clean(title_el.get_text())
        url = title_el.get("href")

        date_el = card.select_one(".event-post-date")
        date_raw = clean(date_el.get_text()) if date_el else ""

        venue_terms = [clean(t.get_text()) for t in card.select(
            ".ucb-event-post-location .wpgb-block-term")]
        is_livestream = any(v.lower() == "livestream" for v in venue_terms)
        physical = [v for v in venue_terms if v.lower() != "livestream"]
        venue = physical[0] if physical else ("Livestream" if is_livestream else "")

        type_terms = [clean(t.get_text()) for t in card.select(
            ".ucb-event-post-comedy-types .wpgb-block-term")]
        if not type_terms:
            type_el = card.select_one(".ucb-event-post-comedy-types")
            if type_el and clean(type_el.get_text()):
                type_terms = [clean(type_el.get_text())]

        img_el = card.select_one("img[data-src]") or card.select_one("img[src]")
        image = safe_url((img_el.get("data-src") or img_el.get("src")) if img_el else None) or None
        # The grid serves a 500x250 thumbnail; WordPress keeps the full-size
        # original at the same URL without the -WxH suffix.
        if image:
            image = _WP_SIZE_SUFFIX.sub("", image)

        excerpt_el = card.select_one(".ucb-event-post-excerpt")
        excerpt = clean(excerpt_el.get_text()) if excerpt_el else ""

        post_id = None
        for cls in card.get("class", []):
            mm = re.match(r"wpgb-post-(\d+)", cls)
            if mm:
                post_id = int(mm.group(1))
                break

        slug = ""
        if url:
            ms = re.search(r"/show/([^/]+)/?", url)
            slug = ms.group(1) if ms else ""
        is_free = "free" in f"{slug.lower()} {title.lower()}"

        start_iso, end_iso, has_time = parse_datetime(date_raw)

        shows.append(make_show(
            post_id=post_id, title=title, url=safe_url(url), slug=slug,
            date_raw=date_raw, start=start_iso, end=end_iso, has_time=has_time,
            venue=venue, venues=venue_terms, is_livestream=is_livestream,
            comedy_types=type_terms, image=image, excerpt=excerpt, is_free=is_free,
            source=source, org=org, city=city,
        ))
    return shows


def fetch(region: str) -> list[dict]:
    source, org, city, url = REGIONS[region]
    return _parse_cards(fetch_html(url), source, org, city)


_CAST_LABEL = re.compile(r"(?:Featuring|Cast|Line\s*-?up)\s*:\s*", re.I)
_CAST_SEPARATOR = re.compile(r"^\s*[—–-]+\s*$")
_CAST_STOP_WORDS = ("ticket", "$", "http", "livestream", "doors", "advance",
                    "in-person", "buyers")
_WP_SIZE_SUFFIX = re.compile(r"-\d+x\d+(?=\.(?:jpe?g|png|webp|gif)$)", re.I)


def _extract_cast(text: str) -> str:
    """Cast list after a Featuring:/Cast:/Lineup: label. UCB pages usually put
    one performer per line, ending at an em-dash separator or the ticket-info
    block, so we walk lines instead of capturing a single one."""
    m = _CAST_LABEL.search(text)
    if not m:
        return ""
    names: list[str] = []
    for raw in text[m.end():].split("\n")[:14]:
        line = clean(raw)
        if not line or _CAST_SEPARATOR.match(line):
            if names:
                break
            continue    # blank right after the label — keep looking
        low = line.lower()
        if len(line) > 80 or any(w in low for w in _CAST_STOP_WORDS):
            break
        if line[-1] in ".!?" and len(line.split()) > 5:
            break       # reads like a sentence, not a name
        names.append(line)
        if len(names) >= 12:
            break
    return clean(", ".join(names))[:400]


def og_image(soup: BeautifulSoup) -> str | None:
    """The page's og:image — usually the full-size hero/poster upload."""
    el = soup.select_one('meta[property="og:image"]')
    return safe_url(el.get("content")) if el else None


def detail(url: str) -> tuple[str, str, str | None]:
    """Fetch a UCB show page → (full description, cast, hero image).
    Best-effort."""
    try:
        soup = BeautifulSoup(fetch_html(url), "lxml")
    except RuntimeError:
        return "", "", None
    el = soup.select_one(".ucb-event-description")
    description = clean(el.get_text(" ")) if el else ""
    cast = _extract_cast(soup.get_text("\n"))
    return description[:2000], cast, og_image(soup)

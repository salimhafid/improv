"""The Second City (Chicago) adapter.

secondcity.com is a Next.js site; the show-finder's date filter is client-side
only, so instead we crawl the /shows/chicago index (~90 show pages) and read
each page's embedded `__NEXT_DATA__`. Every show page carries a base64
"patronticketData" blob from their Salesforce/PatronTicket box office with the
show's full run: one instance per ticketed showtime, with an ISO8601 UTC
timestamp, sold-out flag, and per-instance city (Chicago pages can host
Toronto instances of touring shows — those are filtered out).

Times convert UTC → America/Chicago and are emitted timezone-naive
venue-local, matching the feed convention. The run horizon is capped so a
revue selling through next year doesn't swamp the feed.
"""
from __future__ import annotations

import base64
import json
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from common import clean, fetch_html, make_show, safe_url

BASE = "https://www.secondcity.com"
INDEX = f"{BASE}/shows/chicago"

_CHICAGO = ZoneInfo("America/Chicago")
_HORIZON_DAYS = 42
_WORKERS = 6

_NEXT_DATA = re.compile(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', re.S)
_OG_IMAGE = re.compile(r'property="og:image" content="([^"]+)"')
_NEXT_IMG_URL = re.compile(r"[?&]url=([^&]+)")


def _stage(slug: str, title: str) -> str:
    """Best-effort stage name from the show slug/title."""
    hay = f"{slug} {title}".lower()
    if "mainstage" in hay:
        return "Mainstage"
    if re.search(r"\betc\b|e-t-c|e\.t\.c", hay):
        return "e.t.c. Theater"
    if "skybox" in hay:
        return "Donny's Skybox"
    return ""


def _walk(obj, key):
    """All values for `key` anywhere in a nested JSON structure."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                yield v
            else:
                yield from _walk(v, key)
    elif isinstance(obj, list):
        for item in obj:
            yield from _walk(item, key)


def _decode_blob(raw: str) -> dict | None:
    try:
        return json.loads(base64.b64decode(raw + "=="))
    except Exception:  # noqa: BLE001
        return None


def _image_from_page(html: str) -> str | None:
    m = _OG_IMAGE.search(html)
    if not m:
        return None
    url = m.group(1)
    # Unwrap Next.js' image proxy to the original upload.
    if "/_next/image" in url:
        inner = _NEXT_IMG_URL.search(url)
        if inner:
            from urllib.parse import unquote
            url = unquote(inner.group(1))
    return safe_url(url)


def _parse_show_page(path: str, today: date) -> list[dict]:
    url = f"{BASE}{path}"
    html = fetch_html(url)
    m = _NEXT_DATA.search(html)
    if not m:
        return []
    data = json.loads(m.group(1))

    blob = None
    for raw in _walk(data, "patronticketData"):
        if isinstance(raw, str):
            blob = _decode_blob(raw)
            if blob:
                break
        elif isinstance(raw, dict) and isinstance(raw.get("patronticketData"), str):
            blob = _decode_blob(raw["patronticketData"])
            if blob:
                break
    if not blob:
        return []

    title = clean(blob.get("name") or "")
    if not title:
        return []

    tags = []
    for nodes in _walk(data, "showTags"):
        for node in (nodes or {}).get("nodes", []):
            name = clean(node.get("name", ""))
            if name:
                tags.append("Sketch" if name.lower() == "sketch comedy" else name)
        if tags:
            break

    description = ""
    for desc in _walk(data, "description"):
        if isinstance(desc, str) and "<p" in desc:
            description = clean(re.sub(r"<[^>]+>", " ", desc))
            break

    image = _image_from_page(html)
    slug_base = path.rstrip("/").split("/")[-1]
    venue = _stage(slug_base, title)
    horizon = today + timedelta(days=_HORIZON_DAYS)

    shows: list[dict] = []
    for inst in blob.get("instances", []):
        if inst.get("custom", {}).get("Event_City__c") != "Chicago":
            continue
        iso = (inst.get("formattedDates") or {}).get("ISO8601")
        if not iso:
            continue
        try:
            utc_dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        except ValueError:
            continue
        local = utc_dt.astimezone(_CHICAGO)
        if not (today <= local.date() <= horizon):
            continue
        shows.append(make_show(
            title=title,
            url=url,
            slug=f"{slug_base}/{inst.get('id', local.isoformat())}",
            date_raw=local.strftime("%A, %B %-d @ %-I:%M %p"),
            start=local.replace(tzinfo=None, microsecond=0).isoformat(),
            has_time=True,
            venue=venue,
            venues=[venue] if venue else [],
            comedy_types=tags,
            image=image,
            excerpt=description[:300],
            is_free=False,
            source="second_city",
            org="The Second City",
            city="Chicago",
        ))
        if description:
            shows[-1]["description"] = description[:2000]
    return shows


def fetch(today: date | None = None) -> list[dict]:
    today = today or date.today()
    index_html = fetch_html(INDEX)
    paths = sorted(set(re.findall(r'href="(/shows/chicago/[^"#?]+)"', index_html)))
    if not paths:
        raise RuntimeError("second_city: no show links on the index page")

    shows: list[dict] = []
    def safe(path):
        try:
            return _parse_show_page(path, today)
        except Exception:  # noqa: BLE001 - one bad page must not break the source
            return []
    with ThreadPoolExecutor(max_workers=_WORKERS) as ex:
        for result in ex.map(safe, paths):
            shows.extend(result)
    if not shows:
        raise RuntimeError("second_city: parsed no showtimes from any show page")
    return shows

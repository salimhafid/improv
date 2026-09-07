"""The Second City (Chicago) adapter.

secondcity.com is a Next.js site; the show-finder's date filter is client-side
only, so instead we crawl the /shows/chicago index (~90 show pages) and read
each page's embedded `__NEXT_DATA__`. Every show page carries a base64
"patronticketData" blob from their Salesforce/PatronTicket box office with the
show's full run: one instance per ticketed showtime, with an ISO8601 UTC
timestamp and sold-out flag. Instances used to carry a per-instance city
(Chicago pages hosted Toronto dates of touring shows); the field is gone
today, so it is only honoured when present. The show's stage, tags and copy
come from the page's own show record (`showAttributes` / `showTags`).

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

from common import clean, fetch_html, fetch_json, local_today, make_class, make_show, safe_url, strip_html

BASE = "https://www.secondcity.com"
INDEX = f"{BASE}/shows/chicago"
FIND_A_CLASS = f"{BASE}/find-a-class/chicago"

_CHICAGO = ZoneInfo("America/Chicago")
_HORIZON_DAYS = 180  # the patronticket blobs already carry each show's full
                     # on-sale run, so a longer cap costs zero extra requests
                     # and picks up announced holiday/limited runs
_WORKERS = 6

_NEXT_DATA = re.compile(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', re.S)
_OG_IMAGE = re.compile(r'property="og:image" content="([^"]+)"')
_NEXT_IMG_URL = re.compile(r"[?&]url=([^&]+)")
# showTags mixes genres with rating/policy labels ("Rated R", "21+ Only",
# "Age Requirement 13+", "No Drink Minimum", "Guest Performance"); only the
# genres belong in comedy_types (the app turns every value into a filter chip).
_NON_GENRE_TAG = re.compile(
    r"^(?:rated\b|pg(?:-13)?$|nc-?17|\d{2}\+|age requirement|(?:no |two |2 )?drink minimum"
    r"|guest performance)", re.I)


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


def _show_node(obj) -> dict | None:
    """The page's own show record: the dict carrying the patronticketData blob
    next to showAttributes/showTags. Sibling queries hold *other* shows'
    attributes (the what's-playing rail) and the site-wide accessibility copy,
    so a whole-tree walk for `description`/`venue` is not safe."""
    if isinstance(obj, dict):
        if "patronticketData" in obj and ("showAttributes" in obj or "showTags" in obj):
            return obj
        for v in obj.values():
            found = _show_node(v)
            if found:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = _show_node(v)
            if found:
                return found
    return None


def _page_venue(attrs: dict) -> str:
    """Stage from showAttributes.venue[].name ('Chicago Mainstage',
    'de Maat Studio Theatre - Chicago'); the city suffix is redundant with `city`."""
    for v in attrs.get("venue") or []:
        name = clean(v.get("name")) if isinstance(v, dict) else ""
        if name:
            return re.sub(r"\s*-\s*Chicago$", "", name)
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

    node = _show_node(data) or {}
    attrs = node.get("showAttributes") or {}

    tags = []
    tag_sets = [node["showTags"]] if node.get("showTags") else _walk(data, "showTags")
    for nodes in tag_sets:
        for tag in (nodes or {}).get("nodes", []):
            name = clean(tag.get("name", ""))
            if not name or _NON_GENRE_TAG.match(name):
                continue
            tags.append("Sketch" if name.lower() == "sketch comedy" else name)
        if tags:
            break

    # The show's own copy: the blob's description/detail, else the page's
    # showAttributes.description. Never the first `description` anywhere in
    # __NEXT_DATA__ — that is the site-wide parking/accessibility paragraph.
    description = ""
    for raw_desc in (blob.get("description"), blob.get("detail"), attrs.get("description")):
        description = strip_html(raw_desc)
        if description:
            break

    image = _image_from_page(html)
    slug_base = path.rstrip("/").split("/")[-1]
    venue = _page_venue(attrs) or _stage(slug_base, title)
    horizon = today + timedelta(days=_HORIZON_DAYS)

    shows: list[dict] = []
    for inst in blob.get("instances") or []:
        # PatronTicket no longer stamps instances with Event_City__c; skip only
        # when the key is present and names another city (the Toronto case).
        custom = inst.get("custom") if isinstance(inst.get("custom"), dict) else {}
        inst_city = custom.get("Event_City__c")
        if inst_city and inst_city != "Chicago":
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


# MARK: Classes (Training Center)

_BUILD_ID = re.compile(r'"buildId":"([^"]+)"')


def _find_class_nodes(obj):
    """The find-a-class payload's class list: the (only) array of dicts that
    carry an activenetData key, wherever the dehydrated queries nest it."""
    if isinstance(obj, list) and obj and isinstance(obj[0], dict) and "activenetData" in obj[0]:
        return obj
    if isinstance(obj, dict):
        for v in obj.values():
            found = _find_class_nodes(v)
            if found:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = _find_class_nodes(v)
            if found:
                return found
    return None


def _hero(node: dict) -> dict:
    """The flexibleLayout Hero block (description, image, price, address)."""
    layout = ((node.get("classes") or {}).get("flexibleLayout")) or []
    for block in layout:
        if isinstance(block, dict) and ("price" in block or "description" in block):
            return block
    return {}


def _section_start(row: dict) -> str | None:
    """'2026-08-29T12:00:00r' → '2026-08-29T12:00:00' (Activenet appends a
    stray letter); falls back to the bare beginning date."""
    m = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", row.get("activity_valid_from") or "")
    if m:
        return m.group(1)
    d = row.get("default_beginning_date") or ""
    return d if re.fullmatch(r"\d{4}-\d{2}-\d{2}", d) else None


def _section_schedule(row: dict) -> str:
    """'Saturday,12:00 PM,3h' + the date range → 'Saturdays 12:00 PM · Aug 29 – Oct 17 · 7 sessions'."""
    parts = [p.strip() for p in (row.get("default_pattern_dates") or "").split(",")]
    pattern = f"{parts[0]}s {parts[1]}" if len(parts) >= 2 and parts[0] else ""
    rng = ""
    try:
        b = date.fromisoformat(row.get("default_beginning_date") or "")
        e = date.fromisoformat(row.get("default_ending_date") or "")
        rng = b.strftime('%b %-d') if b == e else f"{b.strftime('%b %-d')} – {e.strftime('%b %-d')}"
    except ValueError:
        pass
    bits = " · ".join(x for x in (pattern, rng) if x)
    sessions = row.get("NUMBEROFSESSIONS")
    if not (bits and sessions):
        return bits
    return f"{bits} · {sessions} {'session' if str(sessions).strip() == '1' else 'sessions'}"


def _no_open_seats(row: dict) -> bool:
    """NUMBER_OPEN is a count that Activenet happens to serialize as a string
    ("0"); compare numerically so an int 0 reads as full too."""
    try:
        return float(row.get("NUMBER_OPEN")) <= 0
    except (TypeError, ValueError):
        return False


def fetch_classes(today: date | None = None) -> list[dict]:
    """Training-center catalog via the same Next.js data layer as shows:
    /_next/data/<buildId>/find-a-class/chicago.json returns every Chicago
    class page with its Activenet section rows (dates, weekly pattern, open
    seats) plus hero metadata (description, image, price). One item per open,
    not-yet-started section; two HTTP requests total."""
    today = today or local_today("Chicago")
    m = _BUILD_ID.search(fetch_html(FIND_A_CLASS))
    if not m:
        raise RuntimeError("second_city: no buildId on the find-a-class page")
    data = fetch_json(f"{BASE}/_next/data/{m.group(1)}/find-a-class/chicago.json")
    nodes = _find_class_nodes(data)
    if not nodes:
        raise RuntimeError("second_city: no class nodes in the find-a-class payload")

    out: list[dict] = []
    for node in nodes:
        try:
            rows = json.loads(((node.get("activenetData") or {}).get("activenetData")) or "[]")
        except (json.JSONDecodeError, TypeError):
            rows = []
        hero = _hero(node)
        cats = ((node.get("classesCategories") or {}).get("nodes")) or []
        level = clean(cats[0].get("name")) if cats else ""
        image = safe_url((hero.get("imageDesktop") or {}).get("mediaItemUrl") or "") or None
        price = clean(hero.get("price"))
        if price and not price.startswith("$") and price[0].isdigit():
            price = f"${price}"   # "395" / "395-675" → "$…"; "Free" stays as is
        description = strip_html(hero.get("description"))
        uri = node.get("uri") or ""
        url = f"{BASE}{uri}" if uri.startswith("/") else safe_url(uri)
        for row in rows:
            if not isinstance(row, dict):
                continue
            if (row.get("activity_status") or "").lower() != "open":
                continue
            start = _section_start(row)
            if not start or start[:10] < today.isoformat():
                continue
            out.append(make_class(
                id=f"second_city/{row.get('activity_id') or row.get('activity_number')}",
                title=clean(row.get("activity_name")) or clean(node.get("title")),
                url=url,
                schedule=_section_schedule(row),
                start=start,
                price=price,
                level=level,
                image=image,
                description=description[:2000],
                is_full=_no_open_seats(row),
                source="second_city", org="The Second City", city="Chicago",
            ))
    return out


def fetch(today: date | None = None) -> list[dict]:
    today = today or local_today("Chicago")
    index_html = fetch_html(INDEX)
    # rstrip so /foo and /foo/ are one page (they'd emit duplicate slugs).
    paths = sorted({p.rstrip("/") for p in re.findall(r'href="(/shows/chicago/[^"#?]+)"', index_html)})
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

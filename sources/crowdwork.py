"""Generic Crowdwork (Fourth Wall) adapter — shared by iO Theater and WGIS.

Crowdwork exposes a clean JSON API: https://www.crowdwork.com/api/v2/<slug>/<kind>
where kind is "shows" or "classes". Each item carries a full description
(`description.body` HTML), poster, venue, tags, and `next_date` (ISO with offset).
"""
from __future__ import annotations

import time
from datetime import date, datetime, timedelta

from common import clean, fetch_json, make_class, make_show, safe_url, strip_html

API = "https://www.crowdwork.com/api/v2/%s/%s?cache=1"

# Recurring shows list their full run in `dates` (a weekly show carries months
# of future performances); cap how far out we expand so a 2027 tail doesn't
# swamp the feed.
_SHOW_HORIZON_DAYS = 90

# Short in-process memo so e.g. wgis_ny + wgis_la don't double-fetch the feed.
_memo: dict[tuple[str, str], tuple[float, list]] = {}
_MEMO_TTL = 120.0


def _fetch(slug: str, kind: str) -> list[dict]:
    key = (slug, kind)
    hit = _memo.get(key)
    if hit and (time.monotonic() - hit[0]) < _MEMO_TTL:
        return hit[1]
    payload = fetch_json(API % (slug, kind))
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list):
        raise RuntimeError(f"crowdwork: unexpected response for {slug}/{kind}")
    _memo[key] = (time.monotonic(), data)
    return data


def _naive_local(iso) -> str | None:
    """Wall-clock portion of '2026-07-15T19:00:00.000-05:00' (drops the offset)."""
    if not isinstance(iso, str) or len(iso) < 19 or iso[10] != "T":
        return None
    return iso[:19]


def _full_description(it: dict) -> str:
    desc = it.get("description")
    if isinstance(desc, dict) and desc.get("body"):
        return strip_html(desc["body"])
    return strip_html(it.get("description_short"))


def _city_from_offset(iso) -> str | None:
    if not isinstance(iso, str):
        return None
    off = iso[19:]  # e.g. "-05:00" or ".000-05:00"
    if "-04:00" in off or "-05:00" in off:
        return "New York"
    if "-07:00" in off or "-08:00" in off:
        return "Los Angeles"
    return None


def _image(it: dict) -> str | None:
    img = it.get("img") or {}
    return safe_url(img.get("large") or img.get("url")) or None


def _is_full(it: dict) -> bool:
    """Best-effort sold-out detection from the item's availability badge.
    Crowdwork has no boolean flag; it surfaces a human string like
    'Only 2 spots left' / 'Sold out' under badges.spots."""
    badges = it.get("badges")
    spots = badges.get("spots") if isinstance(badges, dict) else None
    text = f"{spots or ''}".lower()
    return any(w in text for w in ("sold out", "sold-out", "wait list", "waitlist", "full"))


def _common(it: dict):
    url = it.get("url") or ""
    return {
        "title": clean(it.get("name")),
        "url": safe_url(url),
        "slug": url.rstrip("/").split("/")[-1] if url else "",
        "image": _image(it),
        "tags": [clean(t) for t in ((it.get("tags") or {}).get("public") or [])][:3],
        "cost": (it.get("cost") or {}).get("formatted", ""),
        "venue": clean(it.get("venue")),
        "next_date": it.get("next_date"),
        "active": (it.get("status") or "").lower() == "active",
    }


def fetch_shows(slug: str, source: str, org: str, city: str, *, city_from_tz: bool = False) -> list[dict]:
    today = date.today()
    horizon = today + timedelta(days=_SHOW_HORIZON_DAYS)
    shows: list[dict] = []
    for it in _fetch(slug, "shows"):
        c = _common(it)
        if not c["active"] or not c["title"]:
            continue
        # One item per future performance: `dates` carries the show's full run
        # (next_date unioned in for shows that publish no array), so a weekly
        # show yields every upcoming date instead of only its next one.
        occurrences = {d for d in (it.get("dates") or []) if isinstance(d, str)}
        if isinstance(c["next_date"], str):
            occurrences.add(c["next_date"])
        for iso in sorted(occurrences):
            start = _naive_local(iso)
            if not start:
                continue
            try:
                dt = datetime.strptime(start, "%Y-%m-%dT%H:%M:%S")
            except ValueError:
                continue
            if not (today <= dt.date() <= horizon):
                continue
            item_city = (_city_from_offset(iso) if city_from_tz else city)
            if city_from_tz:
                # Unrecognized/absent offset → city is unknown. Drop it rather
                # than fall back to this source's city, which would otherwise
                # place the same event in BOTH the NY and LA feeds (both runs
                # share one feed).
                if item_city is None or item_city != city:
                    continue
            shows.append(make_show(
                title=c["title"], url=c["url"],
                slug=f"{c['slug']}/{dt.strftime('%Y%m%d%H%M')}",
                date_raw=dt.strftime("%A, %B %-d @ %-I:%M %p"),
                start=start, has_time=True, venue=c["venue"] or org, venues=[c["venue"] or org],
                comedy_types=c["tags"], image=c["image"],
                excerpt=strip_html(it.get("description_short")), description=_full_description(it),
                is_free="free" in f"{c['title']} {c['cost']}".lower(),
                source=source, org=org, city=item_city,
            ))
    return shows


def fetch_classes(slug: str, source: str, org: str, city: str) -> list[dict]:
    today = date.today().isoformat()
    classes: list[dict] = []
    for it in _fetch(slug, "classes"):
        c = _common(it)
        if not c["active"] or not c["title"]:
            continue
        # Date handling: prefer next_date; else use the `dates` array. When a
        # class has explicit dates but they're all in the past (e.g. an intensive
        # whose run ended, with next_date null), drop it — only keep it as an
        # always-show "undated" class when there's no date info at all.
        next_d = _naive_local(c["next_date"])
        run_dates = sorted(p for p in (_naive_local(x) for x in (it.get("dates") or [])) if p)
        if next_d:
            start = next_d
        elif run_dates:
            future = [d for d in run_dates if d[:10] >= today]
            if not future:
                continue
            start = future[0]
        else:
            start = None
        schedule = ""
        if start:
            try:
                schedule = datetime.strptime(start, "%Y-%m-%dT%H:%M:%S").strftime("%A, %B %-d @ %-I:%M %p")
            except ValueError:
                schedule = start
        classes.append(make_class(
            id=f"{source}/{c['slug']}", title=c["title"], url=c["url"],
            schedule=schedule, start=start, price=c["cost"],
            level=(c["tags"][0] if c["tags"] else ""), image=c["image"],
            description=_full_description(it), is_full=_is_full(it),
            source=source, org=org, city=city,
        ))
    return classes

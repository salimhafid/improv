"""Generic Crowdwork (Fourth Wall) adapter — shared by iO Theater and WGIS.

Crowdwork exposes a clean JSON API: https://www.crowdwork.com/api/v2/<slug>/<kind>
where kind is "shows" or "classes". Each item carries a full description
(`description.body` HTML), poster, venue, tags, and `next_date` (ISO with offset).
"""
from __future__ import annotations

import re
import time
from datetime import datetime, timedelta

from bs4 import BeautifulSoup

from common import (block_text, clean, fetch_json, local_today, make_class, make_show, safe_url,
                    strip_html)

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


def _parse_local(iso) -> datetime | None:
    """`_naive_local` as a datetime, or None for anything malformed — a
    well-shaped but impossible '2026-13-45T99:00:00' must not reach the feed."""
    start = _naive_local(iso)
    if not start:
        return None
    try:
        return datetime.strptime(start, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


def _full_description(it: dict) -> str:
    desc = it.get("description")
    if isinstance(desc, dict) and desc.get("body"):
        return strip_html(desc["body"])
    return strip_html(it.get("description_short"))


# The API's `timezone` is a Rails zone name ("Pacific Time (US & Canada)");
# it is unambiguous where a bare offset is not (-05:00 is EST *and* CDT).
_TZ_NAME_CITY = (("eastern", "New York"), ("pacific", "Los Angeles"), ("central", "Chicago"))


def _city_from_tz(it: dict, iso) -> str | None:
    name = it.get("timezone")
    if isinstance(name, str):
        low = name.lower()
        for word, city in _TZ_NAME_CITY:
            if word in low:
                return city
    return _city_from_offset(iso)


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
    img = it.get("img")
    if not isinstance(img, dict):
        return None
    return safe_url(img.get("large") or img.get("url")) or None


_FULL_RE = re.compile(r"sold[ -]?out|wait[ -]?list|\bfull\b")


def _is_full(it: dict) -> bool:
    """Best-effort sold-out detection from the item's availability badge.
    Crowdwork has no boolean flag; it surfaces a human string like
    'Only 2 spots left' / 'Sold out' under badges.spots. "full" is matched
    as a word so "Fully refundable" does not count."""
    badges = it.get("badges")
    spots = badges.get("spots") if isinstance(badges, dict) else None
    return bool(_FULL_RE.search(f"{spots or ''}".lower()))


# Crowdwork tags are mostly visibility/marketing flags ("All Featured Shows",
# "front", "iO Classics"); only genre-like ones may become comedy_types, which
# the app turns into filter chips.
_GENRE_TAGS = {
    "improv", "sketch", "sketch comedy", "stand-up", "standup", "stand up", "musical",
    "musical improv", "character", "clown", "clowning", "storytelling", "variety",
    "podcast", "game show", "jam", "open mic", "comedy",
}


def _genre_tags(tags: list[str]) -> list[str]:
    return [t for t in tags if t.lower() in _GENRE_TAGS]


def _common(it: dict):
    """Fields shared by shows and classes. Every CMS value is type-checked so
    one odd item skips its field instead of failing the whole source."""
    url = it.get("url")
    url = url if isinstance(url, str) else ""
    tags = it.get("tags")
    public = tags.get("public") if isinstance(tags, dict) else None
    cost = it.get("cost")
    status = it.get("status")
    # The slug keys ids; fall back to Crowdwork's numeric id when the URL is
    # missing so url-less items do not all collide on "".
    slug = url.rstrip("/").split("/")[-1] if url else clean(it.get("id"))
    return {
        "title": clean(it.get("name")),
        "url": safe_url(url),
        "slug": slug,
        "image": _image(it),
        "tags": [clean(t) for t in (public if isinstance(public, list) else [])],
        "cost": cost.get("formatted", "") if isinstance(cost, dict) else "",
        "venue": clean(it.get("venue")),
        "next_date": it.get("next_date"),
        "active": isinstance(status, str) and status.lower() == "active",
    }


def fetch_shows(slug: str, source: str, org: str, city: str, *, city_from_tz: bool = False) -> list[dict]:
    today = local_today(city)
    horizon = today + timedelta(days=_SHOW_HORIZON_DAYS)
    shows: list[dict] = []
    for it in _fetch(slug, "shows"):
        c = _common(it)
        if not c["active"] or not c["title"]:
            continue
        # One item per future performance: `dates` carries the show's full run
        # (next_date unioned in for shows that publish no array), so a weekly
        # show yields every upcoming date instead of only its next one. Keyed
        # by wall-clock time so a formatting difference between next_date and
        # its dates[] twin cannot produce a duplicate.
        dates = it.get("dates")
        raw = [d for d in (dates if isinstance(dates, list) else []) if isinstance(d, str)]
        if isinstance(c["next_date"], str):
            raw.append(c["next_date"])
        occurrences: dict[str, str] = {}
        for iso in raw:
            start = _naive_local(iso)
            if start:
                occurrences.setdefault(start, iso)
        for start, iso in sorted(occurrences.items()):
            dt = _parse_local(iso)
            if not dt:
                continue
            if not (today <= dt.date() <= horizon):
                continue
            item_city = (_city_from_tz(it, iso) if city_from_tz else city)
            if city_from_tz:
                # Unrecognized/absent zone → city is unknown. Drop it rather
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
                comedy_types=_genre_tags(c["tags"])[:3], image=c["image"],
                excerpt=strip_html(it.get("description_short")), description=_full_description(it),
                is_free="free" in f"{c['title']} {c['cost']}".lower(),
                source=source, org=org, city=item_city,
            ))
    return shows


# ---- class-only fields ------------------------------------------------------
# The classes API has no instructor field and no end time; everything below is
# derived from what an item does carry (name, dates, location, cost_tiers,
# description.body). The public event page adds nothing to these.

# A teacher is published only in the class name: "... w/ Damian Anaya",
# "... with Max Kantor T127" (a trailing term code). Only a tail made of
# capitalised 2-3 word names counts, so "with TBD", "with 3 SQUARE" (a team)
# or "with class show" yield nothing rather than a wrong name.
_WITH_RE = re.compile(r"^.*(?:\bw/|\bwith)\s*(.+?)(?:\s+T\d+)?\s*$")
_NAME_RE = re.compile(r"[A-Z][A-Za-z.'\u2019-]+(?: [A-Z][A-Za-z.'\u2019-]+){1,2}")
_NOT_A_NAME = {"tbd", "tba", "staff", "guest", "guests", "friends", "show", "team", "class",
               "the", "improv", "comedy", "music", "live"}


def _instructor(title: str) -> str:
    m = _WITH_RE.match(title)
    if not m:
        return ""
    names = re.split(r"\s*(?:,|&|\band\b)\s*", m.group(1))
    for name in names:
        if not _NAME_RE.fullmatch(name) or any(w.lower() in _NOT_A_NAME for w in name.split()):
            return ""
    return ", ".join(names)


_STATE_RE = re.compile(r"[A-Z]{2}(?: \d{5}(?:-\d{4})?)?")


def _location(it: dict, venue: str, city: str) -> str:
    """One line from the API's `location`, which is "<venue> - <address>,
    <city>, <state zip>" with whatever the theatre typed: iO's address field
    already ends in the city and state (so they come twice), The Annoyance's
    city is blank ("851 W Belmont Ave, IL")."""
    loc = clean(it.get("location")) if isinstance(it.get("location"), str) else ""
    if not loc:
        return ""
    room = ""
    if venue and loc.startswith(venue + " - "):
        room, loc = venue, loc[len(venue) + 3:]
    parts = loc.rsplit(", ", 2)
    if len(parts) == 3 and _STATE_RE.fullmatch(parts[2]) and parts[1].lower() in parts[0].lower():
        loc = parts[0]                      # the address already names the city
    elif city.lower() not in loc.lower():
        head, _, state = loc.rpartition(", ")
        if head and _STATE_RE.fullmatch(state):
            loc = f"{head}, {city}, {state}"
    return f"{room}, {loc}" if room else loc


def _clock(dt: datetime) -> str:
    return dt.strftime("%-I:%M%p" if dt.minute else "%-I%p").lower()


_MORE_RE = re.compile(r"\+\s*(\d+)\s+more")


def _grouping(it: dict) -> tuple[bool, int]:
    """(separate, more) from `grouped_dates`. `grouped` False marks dates
    sold one at a time (a weekly drop-in), not the sessions of one course.
    `message` " + 4 more" counts the later sessions of a run, which is all a
    far-out intensive says about it while its `dates` list is still empty."""
    gd = it.get("grouped_dates")
    if not isinstance(gd, dict):
        return False, 0
    m = _MORE_RE.search(gd["message"]) if isinstance(gd.get("message"), str) else None
    return gd.get("grouped") is False, int(m.group(1)) if m else 0


def _schedule(run: list[datetime], first: datetime, today_year: int, monthly: bool,
              unit: str = "sessions") -> str:
    """One line for a class's whole run (`run` sorted, `first` its first
    upcoming session): the meeting pattern, the date range and the number of
    sessions, e.g. "Mondays 7pm · Oct 19 - Dec 14 · 8 sessions". A single
    date keeps the long "Monday, November 9 @ 7:00 PM" form. The API has no
    end time, so none is shown."""
    if len(run) < 2:
        return first.strftime("%A, %B %-d @ %-I:%M %p")
    same_time = len({d.time() for d in run}) == 1
    if same_time and len({d.weekday() for d in run}) == 1:
        lead = f"{run[0].strftime('%A')}s {_clock(run[0])}" + (" monthly" if monthly else "")
    elif same_time and all((b.date() - a.date()).days == 1 for a, b in zip(run, run[1:])):
        lead = f"{run[0].strftime('%a')}-{run[-1].strftime('%a')} {_clock(run[0])}"
    elif len(run) <= 3:
        return ", ".join(f"{d.strftime('%a %b %-d')} {_clock(d)}" for d in run)
    else:
        lead = ""
    a, b = run[0], run[-1]
    if a.year != b.year:
        span = f"{a.strftime('%b %-d, %Y')} - {b.strftime('%b %-d, %Y')}"
    else:
        span = f"{a.strftime('%b %-d')} - {b.strftime('%b %-d')}"
        if b.year != today_year:
            span += f", {b.year}"
    return " \u00b7 ".join(x for x in (lead, span, f"{len(run)} {unit}") if x)


# A tier that is one instalment ("Payment Plan": half the tuition), not a price.
_PART_PAYMENT_RE = re.compile(r"payment plan|deposit|instal", re.I)


def _class_price(it: dict, formatted: str) -> str:
    """The API says "Multiple prices" when a class has several tiers; show
    the range of the paid ones instead (what the checkout lists; the zero
    tiers are code-locked scholar/intern seats)."""
    tiers = it.get("cost_tiers")
    if formatted.strip().lower() != "multiple prices" or not isinstance(tiers, list):
        return formatted
    cents = sorted({t["cost_after_fees"] for t in tiers if isinstance(t, dict)
                    and isinstance(t.get("cost_after_fees"), (int, float))
                    and t["cost_after_fees"] > 0
                    and not _PART_PAYMENT_RE.search(f"{t.get('name') or ''}")})
    if not cents:
        return formatted
    lo, hi = (f"${c / 100:,.2f}" for c in (cents[0], cents[-1]))
    return (lo if lo == hi else f"{lo} - {hi}") + " (includes fees)"


# "LSI_Logo.png", "large_LSI_Logo.png": the school's own logo standing in for
# artwork. Longer names ("Annoyance__Summer_Intensive_Circle_Logo.png") are
# artwork made for the class and are kept.
_SITE_LOGO_RE = re.compile(r"(?:(?:large|medium|thumb)_)?[A-Za-z0-9]+[_ -]+logo\.\w+", re.I)


def _class_image(image):
    """Class artwork only, never the school's logo."""
    if image and _SITE_LOGO_RE.fullmatch(image.rsplit("/", 1)[-1]):
        return None
    return image


# Lines that are about paying or navigating the site, not about the class.
_BOILERPLATE_RE = re.compile(
    r"convenience fees|refund|view all available days|please (?:ignore|disregard) |"
    r"those pertain to our", re.I)
_BIO_HEAD_RE = re.compile(r"(?:instructor|teacher) bios?\s*(?::|$)", re.I)
_LABEL_RE = re.compile(r"[A-Z][A-Za-z /&-]{1,30}:")       # "Schedule:", "Prerequisite: None"


def _class_description(it: dict, title: str) -> str:
    """Paragraph-preserving description without the payment boilerplate, the
    repeated title line and the teacher biography (an "Instructor Bio:"
    heading and what follows it up to the next labelled section)."""
    desc = it.get("description")
    body = desc.get("body") if isinstance(desc, dict) else None
    if not isinstance(body, str) or not body.strip():
        return strip_html(it.get("description_short"))
    lines: list[str] = []
    in_bio = False
    for line in block_text(BeautifulSoup(body, "lxml")).split("\n"):
        line = clean(line)
        if _BIO_HEAD_RE.match(line):
            in_bio = True
            continue
        if in_bio:
            if not _LABEL_RE.match(line):
                continue
            in_bio = False
        if _BOILERPLATE_RE.search(line) or (not any(lines) and line.lower() == title.lower()):
            continue
        lines.append(line)
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    return text or strip_html(it.get("description_short"))


def fetch_classes(slug: str, source: str, org: str, city: str) -> list[dict]:
    today = local_today(city)
    classes: list[dict] = []
    for it in _fetch(slug, "classes"):
        c = _common(it)
        if not c["active"] or not c["title"]:
            continue
        # Date handling: the first upcoming session of next_date + `dates`
        # (a stale past next_date must not hide future run dates). When a
        # class has explicit dates but they're all in the past (e.g. an
        # intensive whose run ended), drop it — only keep it as an always-show
        # "undated" class when there's no date info at all.
        dates = it.get("dates")
        candidates = [c["next_date"]] + (dates if isinstance(dates, list) else [])
        run = sorted({d for d in (_parse_local(x) for x in candidates) if d})
        if run:
            future = [d for d in run if d.date() >= today]
            if not future:
                continue
            start = future[0].isoformat()
            # A course is described by its whole run; separately sold
            # dates only by the ones still to come.
            separate, more = _grouping(it)
            schedule = _schedule(future if separate else run, future[0], today.year,
                                 it.get("recurring") == "Monthly",
                                 "dates" if separate else "sessions")
            if len(run) == 1 and more:
                schedule += f" \u00b7 {more + 1} sessions"
        else:
            start, schedule = None, ""
        classes.append(make_class(
            id=f"{source}/{c['slug']}", title=c["title"], url=c["url"],
            instructor=_instructor(c["title"]), schedule=schedule, start=start,
            price=_class_price(it, c["cost"]),
            level=(c["tags"][0] if c["tags"] else ""), image=_class_image(c["image"]),
            description=_class_description(it, c["title"]),
            location=_location(it, c["venue"], city), is_full=_is_full(it),
            source=source, org=org, city=city,
        ))
    return classes

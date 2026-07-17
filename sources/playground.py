"""The Playground Theater (Chicago) adapter.

Their site is a Canva page whose show-calendar embeds a public Google
Calendar, so the canonical source is that calendar's ICS feed. Events are
largely weekly/monthly RRULEs, expanded here with dateutil over a two-month
horizon, honoring EXDATEs, cancellations, and RECURRENCE-ID overrides.
Every show at The Playground is free (per the theater's own banner).
"""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from dateutil import rrule as du_rrule

from common import clean, fetch_html, make_show

ICS_URL = ("https://calendar.google.com/calendar/ical/"
           "c_eb31034f2f607e78639715490267dbb491e72cbd150c14e0269bf9adb111b126"
           "%40group.calendar.google.com/public/basic.ics")
PAGE_URL = "https://theplaygroundtheater.com/show-calendar"

_CHICAGO = ZoneInfo("America/Chicago")
_HORIZON_DAYS = 62


def _unfold(text: str) -> list[str]:
    """RFC 5545 line unfolding (continuation lines start with a space/tab)."""
    lines: list[str] = []
    for raw in text.splitlines():
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    return lines


def _unescape(value: str) -> str:
    return (value.replace("\\n", " ").replace("\\N", " ")
            .replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\"))


def _parse_dt(value: str) -> datetime | None:
    """ICS datetime → aware Chicago datetime (dates count as all-day)."""
    value = value.strip()
    try:
        if value.endswith("Z"):
            return (datetime.strptime(value, "%Y%m%dT%H%M%SZ")
                    .replace(tzinfo=ZoneInfo("UTC")).astimezone(_CHICAGO))
        if "T" in value:
            return datetime.strptime(value, "%Y%m%dT%H%M%S").replace(tzinfo=_CHICAGO)
        return datetime.strptime(value, "%Y%m%d").replace(tzinfo=_CHICAGO)
    except ValueError:
        return None


def _events(ics: str) -> list[dict]:
    events: list[dict] = []
    current: dict | None = None
    for line in _unfold(ics):
        if line == "BEGIN:VEVENT":
            current = {"exdates": set()}
        elif line == "END:VEVENT":
            if current is not None:
                events.append(current)
            current = None
        elif current is not None and ":" in line:
            key, value = line.split(":", 1)
            name = key.split(";")[0].upper()
            if name == "DTSTART":
                current["start"] = _parse_dt(value)
                current["all_day"] = "T" not in value
            elif name == "RRULE":
                current["rrule"] = value
            elif name == "EXDATE":
                dt = _parse_dt(value)
                if dt:
                    current["exdates"].add(dt)
            elif name == "RECURRENCE-ID":
                current["recurrence_id"] = _parse_dt(value)
            elif name in ("SUMMARY", "DESCRIPTION", "STATUS", "UID"):
                current[name.lower()] = _unescape(value.strip())
    return events


def fetch(today: date | None = None) -> list[dict]:
    today = today or date.today()
    window_start = datetime.combine(today, datetime.min.time(), tzinfo=_CHICAGO)
    window_end = window_start + timedelta(days=_HORIZON_DAYS)

    events = _events(fetch_html(ICS_URL))
    if not events:
        raise RuntimeError("playground: no VEVENTs in the Google Calendar ICS")

    # Occurrences replaced or cancelled by RECURRENCE-ID overrides.
    overridden = {(e.get("uid"), e.get("recurrence_id"))
                  for e in events if e.get("recurrence_id")}

    shows: list[dict] = []
    seen: set[str] = set()

    def emit(title: str, description: str, dt: datetime, all_day: bool) -> None:
        local = dt.astimezone(_CHICAGO).replace(tzinfo=None, microsecond=0)
        key = f"{title}/{local.isoformat()}"
        if key in seen:
            return
        seen.add(key)
        shows.append(make_show(
            title=title,
            url=PAGE_URL,
            slug=re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") + local.strftime("/%Y%m%d%H%M"),
            date_raw=(local.strftime("%A, %B %-d") if all_day
                      else local.strftime("%A, %B %-d @ %-I:%M %p")),
            start=local.isoformat() if not all_day else local.date().isoformat(),
            has_time=not all_day,
            venue="The Playground Theater",
            venues=["The Playground Theater"],
            comedy_types=["Improv"],
            image=None,
            description=description[:2000],
            excerpt=description[:240],
            is_free=True,   # "All shows are FREE" — the theater's own banner
            source="playground",
            org="The Playground Theater",
            city="Chicago",
        ))

    for ev in events:
        if (ev.get("status") or "").upper() == "CANCELLED":
            continue
        title = clean(ev.get("summary", ""))
        start = ev.get("start")
        if not title or not start:
            continue
        description = clean(re.sub(r"<[^>]+>", " ", ev.get("description", "")))

        if ev.get("rrule"):
            try:
                rule = du_rrule.rrulestr(ev["rrule"], dtstart=start)
                occurrences = rule.between(window_start, window_end, inc=True)
            except (ValueError, TypeError):
                occurrences = []
            for occ in occurrences:
                if occ in ev["exdates"] or (ev.get("uid"), occ) in overridden:
                    continue
                emit(title, description, occ, ev.get("all_day", False))
        else:
            if window_start <= start <= window_end:
                emit(title, description, start, ev.get("all_day", False))

    if not shows:
        raise RuntimeError("playground: no upcoming occurrences in window")
    return shows

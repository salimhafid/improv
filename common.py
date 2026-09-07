"""Shared scraping utilities for all venue adapters.

Sites variously sit behind Cloudflare and use different stacks (WordPress,
Squarespace, Wix), so we fetch with curl_cffi browser TLS impersonation and
normalize every source into one show dict shape.
"""
from __future__ import annotations

import logging
import re
import time
from datetime import date, datetime, timezone
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

from bs4 import BeautifulSoup
from curl_cffi import requests as cffi_requests
from dateutil import parser as dateparser

log = logging.getLogger("ucb.common")

# Rotated across retries — if one TLS fingerprint gets challenged, try another.
IMPERSONATE_TARGETS = ["chrome", "chrome120", "safari"]

_MONTHS = (
    "January|February|March|April|May|June|July|August|"
    "September|October|November|December"
)


CITY_TZ = {
    "New York": ZoneInfo("America/New_York"),
    "Los Angeles": ZoneInfo("America/Los_Angeles"),
    "Chicago": ZoneInfo("America/Chicago"),
    # UCB schedules its online classes in Eastern time.
    "Online": ZoneInfo("America/New_York"),
}


def local_today(city: str, now: datetime | None = None) -> date:
    """Today in the venue's own timezone. The feed stores venue-local naive
    times, but GitHub runners live in UTC — a bare date.today() there is
    already 'tomorrow' from 5pm PT onward, which used to wipe every remaining
    same-night show from the evening feed builds. Unknown cities fall back to
    New York (the earliest US zone we cover, so the most conservative cut)."""
    now = now or datetime.now(timezone.utc)
    return now.astimezone(CITY_TZ.get(city, CITY_TZ["New York"])).date()


# Statuses that will not change on a retry with a different fingerprint. 403
# is deliberately absent: Cloudflare answers a rejected TLS fingerprint with a
# 403 (ucbcomedy.com does so for chrome120 while chrome/safari get 200), so it
# is exactly the case the rotation exists for.
_NO_RETRY_STATUSES = {404, 410}
# (host, status) pairs whose body has already been logged this process, so a
# blocked host (e.g. ucbcomedy.com's bare 202 to the Actions runner) is
# captured once for diagnosis instead of on every URL.
_logged_bodies: set[tuple[str, int]] = set()


def _looks_challenged(body: str) -> bool:
    low = body.lower()
    return "just a moment" in low or "cf_chl" in low


def _log_bad_response(url: str, resp, target: str) -> None:
    key = (urlsplit(url).netloc, resp.status_code)
    if key in _logged_bodies:
        return
    _logged_bodies.add(key)
    log.warning("%s answered status=%d (impersonate=%s); body starts: %r",
                url, resp.status_code, target, resp.text[:200])


def _request(method: str, url: str, *, data=None, as_json: bool = False, retries: int = 3):
    """One request with impersonation rotation and backoff. Returns the body
    text, or the decoded JSON when as_json. Raises RuntimeError on failure.
    A 202 is treated as a challenge: ucbcomedy.com answers the runner with it
    instead of a 'just a moment' page. Non-retryable statuses short-circuit."""
    last_err = None
    attempts = 0
    for attempt in range(retries):
        attempts = attempt + 1
        target = IMPERSONATE_TARGETS[attempt % len(IMPERSONATE_TARGETS)]
        try:
            resp = cffi_requests.request(method, url, data=data, impersonate=target, timeout=30)
            challenged = resp.status_code == 202 or _looks_challenged(resp.text)
            payload = None
            if resp.status_code == 200 and as_json:
                # A JSON body is never a challenge page if it decodes; a
                # non-JSON 200 (HTML interstitial) is retried like one.
                try:
                    payload = resp.json()
                except ValueError as e:
                    last_err = f"non-JSON body challenged={challenged} impersonate={target}: {e}"
            elif resp.status_code == 200 and not challenged:
                payload = resp.text
            else:
                last_err = f"status={resp.status_code} challenged={challenged} impersonate={target}"
            if payload is not None:
                log.info("fetched %s (%d bytes, impersonate=%s)", url, len(resp.text), target)
                return payload
            _log_bad_response(url, resp, target)
            if resp.status_code in _NO_RETRY_STATUSES:
                break
        except Exception as e:  # noqa: BLE001
            last_err = repr(e)
        if attempt < retries - 1:
            time.sleep(2 ** attempt)
    raise RuntimeError(f"failed to fetch {url} after {attempts} attempts: {last_err}")


def fetch_html(url: str, retries: int = 3) -> str:
    """Fetch a page past Cloudflare. Raises RuntimeError on failure."""
    return _request("GET", url, retries=retries)


def fetch_json(url: str, retries: int = 3):
    """Fetch + JSON-decode a URL with the same impersonation/retries."""
    return _request("GET", url, as_json=True, retries=retries)


def post_json(url: str, data: dict, retries: int = 3):
    """POST a form body and JSON-decode the answer, with the same hardening
    (status check, impersonation rotation, challenge check, retries)."""
    return _request("POST", url, data=data, as_json=True, retries=retries)


_BLOCK_TAGS = {"p", "div", "section", "article", "blockquote",
               "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "tr"}


def block_text(el) -> str:
    """Paragraph-preserving text extraction for description HTML: block
    elements become blank-line breaks, <br> a line break, <li> a bullet —
    so the app can render copy with the site's structure instead of one
    mashed-together line."""
    from bs4 import NavigableString, Tag

    def walk(node) -> str:
        if isinstance(node, NavigableString):
            return str(node)
        if not isinstance(node, Tag):
            return ""
        if node.name == "br":
            return "\n"
        if node.name in ("script", "style"):
            return ""
        inner = "".join(walk(c) for c in node.children)
        if node.name == "li":
            return "\u2022 " + inner.strip() + "\n"
        if node.name in _BLOCK_TAGS:
            return inner.strip() + "\n\n"
        return inner

    text = walk(el)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" ?\n ?", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def clean(text) -> str:
    """Collapse whitespace. Tolerates non-string CMS values (ints, lists, dicts)
    so a single odd field skips rather than crashing a whole source."""
    if not text:
        return ""
    if not isinstance(text, str):
        text = str(text)
    return re.sub(r"\s+", " ", text).strip()


def safe_url(url) -> str:
    """Allow only http(s) URLs; block javascript:/data: etc. from third-party data.
    Non-string CMS values (ints, dicts) yield "" rather than crashing a source."""
    if not isinstance(url, str):
        return ""
    url = url.strip()
    if url and re.match(r"https?://", url, re.I):
        return url
    return ""


def strip_html(s) -> str:
    """Plain text from an HTML fragment (e.g. Squarespace/Wix excerpts).
    Tolerates non-string values."""
    if not s:
        return ""
    if not isinstance(s, str):
        return clean(s)
    return clean(BeautifulSoup(s, "lxml").get_text(" "))


# A trailing end time ("7:00 PM - 9:00 PM"): the range trigger below would
# otherwise send the whole string to a fuzzy parse that fails, or reads an
# un-spaced "-9:00" as a UTC offset.
_TRAILING_END_TIME = re.compile(
    r"(\d{1,2}(?::\d{2})?\s*[AaPp]\.?[Mm]\.?)\s*[–—-]\s*\d{1,2}(?::\d{2})?\s*[AaPp]\.?[Mm]\.?\s*$")


def parse_datetime(date_raw: str):
    """Parse a date string into (start_iso, end_iso, has_time).

    Handles "Friday, June 19, 2026 @ 7:00 PM" (optionally "- 9:00 PM") and
    ranges "Friday, June 12 - Sunday, June 14, 2026". The start is always a
    naive venue-local ISO string. Unparseable -> (None, None, False).
    """
    if not date_raw:
        return None, None, False
    text = date_raw.replace("\xa0", " ").strip()
    text = _TRAILING_END_TIME.sub(r"\1", text)

    if re.search(r"\d\s*[–—-]\s*[A-Za-z0-9]", text):
        # The optional day-name eater must not swallow a month name, or
        # "June 28 - July 2" would parse its end date as June 2.
        m = re.search(
            rf"({_MONTHS})\s+(\d{{1,2}})\s*[–—-]\s*"
            rf"(?:(?!(?:{_MONTHS})\b)[A-Za-z]+,?\s*)?(?:({_MONTHS})\s+)?(\d{{1,2}}),?\s+(\d{{4}})",
            text,
        )
        if m:
            m1, d1, m2, d2, year = m.groups()
            m2 = m2 or m1
            try:
                start = dateparser.parse(f"{m1} {d1}, {year}").date()
                end = dateparser.parse(f"{m2} {d2}, {year}").date()
                if start > end:
                    # The single trailing year belongs to the end date:
                    # "December 30 - January 2, 2027" starts in 2026.
                    start = start.replace(year=start.year - 1)
                return start.isoformat(), end.isoformat(), False
            except (ValueError, OverflowError):
                pass

    try:
        dt = dateparser.parse(text.replace("@", " "), fuzzy=True)
        if dt.tzinfo is not None:
            # A stray "-9:00" reads as a UTC offset; the feed is venue-local
            # naive and the app cannot parse an offset.
            dt = dt.replace(tzinfo=None)
        has_time = bool(re.search(r"\d{1,2}:\d{2}", text))
        return dt.isoformat(), None, has_time
    except (ValueError, OverflowError):
        return None, None, False


def make_show(**kw) -> dict:
    """A normalized show dict with safe defaults. Adapters override fields and
    must set source/org/city. `description` is the full blurb (excerpt is short);
    `cast` is the lineup/featuring text when available."""
    base = {
        "post_id": None, "title": "", "url": "", "slug": "", "date_raw": "",
        "start": None, "end": None, "has_time": False, "venue": "", "venues": [],
        "is_livestream": False, "comedy_types": [], "image": None, "excerpt": "",
        "description": "", "cast": "",
        "is_free": False, "source": "", "org": "", "city": "",
    }
    base.update(kw)
    return base


def make_class(**kw) -> dict:
    """A normalized class dict with safe defaults. Adapters must set
    source/org/city."""
    base = {
        "id": "", "title": "", "url": "", "instructor": "", "schedule": "",
        "start": None, "price": "", "level": "", "image": None, "description": "",
        "is_full": False, "source": "", "org": "", "city": "",
    }
    base.update(kw)
    return base

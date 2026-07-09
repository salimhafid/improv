"""Shared scraping utilities for all venue adapters.

Sites variously sit behind Cloudflare and use different stacks (WordPress,
Squarespace, Wix), so we fetch with curl_cffi browser TLS impersonation and
normalize every source into one show dict shape.
"""
from __future__ import annotations

import logging
import re
import time

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


def fetch_html(url: str, retries: int = 3) -> str:
    """Fetch a page past Cloudflare. Raises RuntimeError on failure."""
    last_err = None
    for attempt in range(retries):
        target = IMPERSONATE_TARGETS[attempt % len(IMPERSONATE_TARGETS)]
        try:
            resp = cffi_requests.get(url, impersonate=target, timeout=30)
            challenged = "just a moment" in resp.text.lower() or "cf_chl" in resp.text.lower()
            if resp.status_code == 200 and not challenged:
                log.info("fetched %s (%d bytes, impersonate=%s)", url, len(resp.text), target)
                return resp.text
            last_err = f"status={resp.status_code} challenged={challenged} impersonate={target}"
        except Exception as e:  # noqa: BLE001
            last_err = repr(e)
        time.sleep(2 ** attempt)
    raise RuntimeError(f"failed to fetch {url} after {retries} attempts: {last_err}")


def fetch_json(url: str, retries: int = 3):
    """Fetch + JSON-decode a URL with the same impersonation/retries."""
    last_err = None
    for attempt in range(retries):
        target = IMPERSONATE_TARGETS[attempt % len(IMPERSONATE_TARGETS)]
        try:
            resp = cffi_requests.get(url, impersonate=target, timeout=30)
            if resp.status_code == 200:
                return resp.json()
            last_err = f"status={resp.status_code}"
        except Exception as e:  # noqa: BLE001
            last_err = repr(e)
        time.sleep(2 ** attempt)
    raise RuntimeError(f"failed to fetch json {url} after {retries} attempts: {last_err}")


def clean(text) -> str:
    """Collapse whitespace. Tolerates non-string CMS values (ints, lists, dicts)
    so a single odd field skips rather than crashing a whole source."""
    if not text:
        return ""
    if not isinstance(text, str):
        text = str(text)
    return re.sub(r"\s+", " ", text).strip()


def safe_url(url: str | None) -> str:
    """Allow only http(s) URLs; block javascript:/data: etc. from third-party data."""
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


def wix_image_url(s: str | None) -> str | None:
    """Convert a Wix image ref ('wix:image://v1/<mediaId>/name#...') to an https URL."""
    if not s:
        return None
    m = re.match(r"wix:image://v1/([^/]+)/", s)
    if m:
        return f"https://static.wixstatic.com/media/{m.group(1)}"
    return safe_url(s) or None


def parse_datetime(date_raw: str):
    """Parse a date string into (start_iso, end_iso, has_time).

    Handles "Friday, June 19, 2026 @ 7:00 PM" and ranges
    "Friday, June 12 - Sunday, June 14, 2026". Unparseable -> (None, None, False).
    """
    if not date_raw:
        return None, None, False
    text = date_raw.replace("\xa0", " ").strip()

    if re.search(r"\d\s*[–—-]\s*[A-Za-z0-9]", text):
        m = re.search(
            rf"({_MONTHS})\s+(\d{{1,2}})\s*[–—-]\s*"
            rf"(?:[A-Za-z]+,?\s*)?(?:({_MONTHS})\s+)?(\d{{1,2}}),?\s+(\d{{4}})",
            text,
        )
        if m:
            m1, d1, m2, d2, year = m.groups()
            m2 = m2 or m1
            try:
                start = dateparser.parse(f"{m1} {d1}, {year}").date()
                end = dateparser.parse(f"{m2} {d2}, {year}").date()
                return start.isoformat(), end.isoformat(), False
            except (ValueError, OverflowError):
                pass

    try:
        dt = dateparser.parse(text.replace("@", " "), fuzzy=True)
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

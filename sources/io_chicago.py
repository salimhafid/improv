"""iO Theater (Chicago) — shows and classes via the shared Crowdwork adapter."""
from __future__ import annotations

from . import crowdwork

SLUG = "iotheater"
ORG = "iO Theater"
CITY = "Chicago"


def fetch() -> list[dict]:
    return crowdwork.fetch_shows(SLUG, "io_chicago", ORG, CITY)


def fetch_classes() -> list[dict]:
    return crowdwork.fetch_classes(SLUG, "io_chicago", ORG, CITY)

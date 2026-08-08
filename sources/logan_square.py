"""Logan Square Improv (Chicago) — shows and classes via the shared Crowdwork
adapter (slug "lsi"; their /events/ page is a Crowdwork widget on the same
API). The bare endpoint returns every active show with its full dates[] run,
so the old hand-rolled 28-day-window pagination was unnecessary — verified
2026-07-22: the shared adapter's output is a strict superset of the windowed
one's, with descriptions and artwork on every occurrence."""
from __future__ import annotations

from . import crowdwork

SLUG = "lsi"
ORG = "Logan Square Improv"
CITY = "Chicago"


def fetch() -> list[dict]:
    return crowdwork.fetch_shows(SLUG, "logan_square", ORG, CITY)


def fetch_classes() -> list[dict]:
    return crowdwork.fetch_classes(SLUG, "logan_square", ORG, CITY)

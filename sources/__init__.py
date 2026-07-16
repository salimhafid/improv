"""Source registries. SOURCES = show adapters; CLASS_SOURCES = class adapters.
Each entry has a stable id, display org, city, and a `fetch()` returning
normalized dicts. The aggregators run them resiliently with per-source cadence."""
from __future__ import annotations

from . import annoyance, brooklyn_cc, io_chicago, magnet, second_city, ucb, ucb_classes, wgis

SOURCES = [
    {"id": "ucb_ny", "org": "UCB", "city": "New York", "fetch": lambda: ucb.fetch("ny"), "detail": ucb.detail},
    {"id": "ucb_la", "org": "UCB", "city": "Los Angeles", "fetch": lambda: ucb.fetch("la"), "detail": ucb.detail},
    {"id": "brooklyn_cc", "org": "Brooklyn Comedy Collective", "city": "New York", "fetch": brooklyn_cc.fetch},
    {"id": "magnet", "org": "Magnet Theater", "city": "New York", "fetch": magnet.fetch, "detail": magnet.detail},
    {"id": "wgis_ny", "org": "WGIS", "city": "New York", "fetch": wgis.fetch_shows_ny},
    {"id": "wgis_la", "org": "WGIS", "city": "Los Angeles", "fetch": wgis.fetch_shows_la},
    {"id": "annoyance", "org": "The Annoyance", "city": "Chicago", "fetch": annoyance.fetch},
    {"id": "io_chicago", "org": "iO Theater", "city": "Chicago", "fetch": io_chicago.fetch},
    {"id": "second_city", "org": "The Second City", "city": "Chicago", "fetch": second_city.fetch},
]

CLASS_SOURCES = [
    {"id": "ucb_ny", "org": "UCB", "city": "New York", "fetch": ucb_classes.fetch_ny},
    {"id": "brooklyn_cc", "org": "Brooklyn Comedy Collective", "city": "New York", "fetch": brooklyn_cc.fetch_classes},
    {"id": "magnet", "org": "Magnet Theater", "city": "New York", "fetch": magnet.fetch_classes},
    {"id": "wgis_ny", "org": "WGIS", "city": "New York", "fetch": wgis.fetch_classes_ny},
    {"id": "ucb_la", "org": "UCB", "city": "Los Angeles", "fetch": ucb_classes.fetch_la},
    {"id": "wgis_la", "org": "WGIS", "city": "Los Angeles", "fetch": wgis.fetch_classes_la},
    {"id": "annoyance", "org": "The Annoyance", "city": "Chicago", "fetch": annoyance.fetch_classes},
    {"id": "io_chicago", "org": "iO Theater", "city": "Chicago", "fetch": io_chicago.fetch_classes},
]

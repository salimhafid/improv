"""Offline adapter tests for the Chicago/NY sources fixed in the deep-read pass
(Second City, Playground, Magnet, Annoyance, Brooklyn CC): synthetic fixtures
+ patched fetchers. No network.

Run: .venv/bin/python -m unittest tests.test_sources_chicago_ny
"""
from __future__ import annotations

import base64
import json
import unittest
from datetime import date, datetime
from unittest.mock import patch
from zoneinfo import ZoneInfo

from sources import annoyance, brooklyn_cc, magnet, playground, second_city


# ---- Second City (show pages) ---------------------------------------------

_PARKING = "<p>The Second City provides accessible parking and seating at every performance.</p>"


def _sc_instance(iid: str, iso: str, custom=None) -> dict:
    inst = {"id": iid, "formattedDates": {"ISO8601": iso}, "soldOut": False}
    if custom is not None:
        inst["custom"] = custom
    return inst


def _sc_show_html(instances, tags=("21+ Only", "Guest Performance", "Improv"),
                  venue_name="de Maat Studio Theatre - Chicago",
                  blob_description="",
                  attrs_description="<div>Mary Shelley&#8217;s monster, with help.</div>") -> str:
    blob = {"name": "420 Frankenstein", "description": blob_description, "detail": "",
            "instances": list(instances)}
    raw = base64.b64encode(json.dumps(blob).encode()).decode().rstrip("=")
    # Mirrors the live page: the site-wide accessibility copy (the first `<p`
    # description in tree order) sits BEFORE the show record, whose blob is
    # nested one level under `patronticketData`.
    show = {
        "locations": {"nodes": [{"accessibilityInfo": {"infoList": [{"description": _PARKING}]}}]},
        "patronticketData": {"patronticketData": raw},
        "showAttributes": {
            "description": attrs_description,
            "venue": [{"name": venue_name}] if venue_name else [],
        },
        "showTags": {"nodes": [{"name": t} for t in tags]},
        "title": "420 Frankenstein",
    }
    data = {"props": {"pageProps": {"dehydratedState": {"queries": [{"state": {"data": show}}]}}}}
    return ('<html><head><meta property="og:image" content="https://sc.test/hero.jpg"></head>'
            '<script id="__NEXT_DATA__" type="application/json">'
            + json.dumps(data) + "</script></html>")


class SecondCityShowPageTests(unittest.TestCase):
    TODAY = date(2026, 9, 7)

    def _parse(self, html, path="/shows/chicago/420-frankenstein-chi"):
        with patch.object(second_city, "fetch_html", return_value=html):
            return second_city._parse_show_page(path, self.TODAY)

    def test_instances_without_event_city_are_kept(self):
        # H1: PatronTicket dropped Event_City__c; only a present, non-Chicago
        # value (the old Toronto case) may skip an instance.
        html = _sc_show_html([
            _sc_instance("a1", "2026-09-10T01:00:00Z", custom={"Number_of_Public_Seats__c": 60}),
            _sc_instance("a2", "2026-09-11T01:00:00Z", custom={"Event_City__c": "Toronto"}),
            _sc_instance("a3", "2026-09-12T01:00:00Z", custom={"Event_City__c": "Chicago"}),
            _sc_instance("a4", "2026-09-13T01:00:00Z"),            # no custom at all
        ])
        shows = self._parse(html)
        self.assertEqual([s["slug"] for s in shows],
                         ["420-frankenstein-chi/a1", "420-frankenstein-chi/a3", "420-frankenstein-chi/a4"])
        self.assertEqual(shows[0]["start"], "2026-09-09T20:00:00")   # 01:00Z → 8 PM CDT

    def test_stage_from_show_attributes_venue_with_slug_fallback(self):
        html = _sc_show_html([_sc_instance("a1", "2026-09-10T01:00:00Z")])
        (s,) = self._parse(html)
        self.assertEqual(s["venue"], "de Maat Studio Theatre")   # "- Chicago" suffix dropped
        self.assertEqual(s["venues"], ["de Maat Studio Theatre"])
        html = _sc_show_html([_sc_instance("a1", "2026-09-10T01:00:00Z")], venue_name="")
        (s,) = self._parse(html, path="/shows/chicago/revue-mainstage-chi")
        self.assertEqual(s["venue"], "Mainstage")

    def test_description_is_the_shows_own_copy_not_the_parking_paragraph(self):
        # M20: the first `<p` description in the tree is site-wide boilerplate.
        html = _sc_show_html([_sc_instance("a1", "2026-09-10T01:00:00Z")])
        (s,) = self._parse(html)
        self.assertEqual(s["description"], "Mary Shelley’s monster, with help.")   # entity unescaped
        self.assertEqual(s["excerpt"], s["description"])
        self.assertNotIn("parking", s["description"])
        # The blob's own description wins over showAttributes when present.
        html = _sc_show_html([_sc_instance("a1", "2026-09-10T01:00:00Z")],
                             blob_description="<p>Blob copy.</p>")
        (s,) = self._parse(html)
        self.assertEqual(s["description"], "Blob copy.")

    def test_rating_and_policy_tags_are_not_comedy_types(self):
        # M21: only genre tags become filter chips.
        html = _sc_show_html([_sc_instance("a1", "2026-09-10T01:00:00Z")],
                             tags=("Rated R", "21+ Only", "Age Requirement 13+", "No Drink Minimum",
                                   "Guest Performance", "Sketch Comedy", "Improv"))
        (s,) = self._parse(html)
        self.assertEqual(s["comedy_types"], ["Sketch", "Improv"])

    def test_index_paths_dedupe_trailing_slash(self):
        index = ('<a href="/shows/chicago/420-frankenstein-chi">x</a>'
                 '<a href="/shows/chicago/420-frankenstein-chi/">y</a>')
        page = _sc_show_html([_sc_instance("a1", "2026-09-10T01:00:00Z")])
        calls = []

        def fake(url):
            calls.append(url)
            return index if url == second_city.INDEX else page
        with patch.object(second_city, "fetch_html", side_effect=fake):
            shows = second_city.fetch(self.TODAY)
        self.assertEqual(len(shows), 1, "the same page crawled twice would emit duplicate slugs")
        self.assertEqual(len([u for u in calls if "420-frankenstein" in u]), 1)


# ---- Second City (classes) ------------------------------------------------

def _sc_class_payload(sections, price="395"):
    return {"pageProps": {"dehydratedState": {"queries": [{"state": {"data": {"classes": {"nodes": [{
        "title": "Improv 1", "uri": "/classes/chicago/improv/improv-1-chi",
        "activenetData": {"activenetData": json.dumps(sections)},
        "classesCategories": {"nodes": [{"name": "Improv"}]},
        "classes": {"flexibleLayout": [{"description": "<p>Yes, and.</p>", "price": price}]},
    }]}}}}]}}}


class SecondCityClassTests(unittest.TestCase):
    def _fetch(self, sections, price="395", today=date(2026, 7, 22)):
        with patch.object(second_city, "fetch_html", return_value='x "buildId":"BID" x'), \
             patch.object(second_city, "fetch_json", return_value=_sc_class_payload(sections, price)):
            return second_city.fetch_classes(today)

    def test_free_price_is_not_dollar_prefixed(self):
        row = {"activity_id": "1", "activity_status": "Open", "activity_valid_from": "2026-08-29T12:00:00r",
               "NUMBER_OPEN": "8"}
        self.assertEqual(self._fetch([row], price="Free")[0]["price"], "Free")
        self.assertEqual(self._fetch([row], price="395")[0]["price"], "$395")

    def test_number_open_compared_numerically(self):
        rows = [dict(activity_id=str(i), activity_status="Open", activity_valid_from="2026-08-29T12:00:00r",
                     NUMBER_OPEN=n) for i, n in enumerate((0, "0", "3", None))]
        self.assertEqual([c["is_full"] for c in self._fetch(rows)], [True, True, False, False])

    def test_single_session_schedule_wording(self):
        row = {"default_pattern_dates": "Saturday,12:00 PM,3h", "default_beginning_date": "2026-09-09",
               "default_ending_date": "2026-09-09", "NUMBEROFSESSIONS": "1"}
        self.assertEqual(second_city._section_schedule(row), "Saturdays 12:00 PM · Sep 9 · 1 session")
        row.update(default_ending_date="2026-10-17", NUMBEROFSESSIONS="7")
        self.assertEqual(second_city._section_schedule(row),
                         "Saturdays 12:00 PM · Sep 9 – Oct 17 · 7 sessions")


# ---- Playground (ICS) -----------------------------------------------------

def _ics(*lines: str) -> str:
    return "\n".join(("BEGIN:VCALENDAR", *lines, "END:VCALENDAR"))


def _vevent(*lines: str) -> str:
    return "\n".join(("BEGIN:VEVENT", *lines, "END:VEVENT"))


class PlaygroundIcsTests(unittest.TestCase):
    def _fetch(self, ics, today=date(2026, 7, 1)):
        with patch.object(playground, "fetch_html", return_value=ics):
            return playground.fetch(today)

    def test_z_form_until_expands(self):
        # H2: the Z-form UNTIL Google emits for every timed series must not be
        # rewritten (the old lookahead backtracked and doubled the value).
        ics = _ics(_vevent("SUMMARY:First Wave Misandry",
                           "DTSTART;TZID=America/Chicago:20260701T200000",
                           "RRULE:FREQ=WEEKLY;UNTIL=20260716T045959Z"))
        shows = self._fetch(ics)
        self.assertEqual([s["start"] for s in shows],
                         ["2026-07-01T20:00:00", "2026-07-08T20:00:00", "2026-07-15T20:00:00"])

    def test_one_off_all_day_entries_are_skipped_and_logged(self):
        # L22: "Happy Labor Day" is a calendar note, not a show.
        ics = _ics(_vevent("SUMMARY:Happy Labor Day", "DTSTART;VALUE=DATE:20260907"),
                   _vevent("SUMMARY:Real Show", "DTSTART:20260907T200000"))
        with self.assertLogs("ucb.playground", level="INFO") as cm:
            shows = self._fetch(ics, today=date(2026, 9, 7))
        self.assertEqual([s["title"] for s in shows], ["Real Show"])
        self.assertTrue(any("skipping all-day" in m for m in cm.output))

    def test_all_day_override_of_a_recurring_series_is_kept(self):
        # A RECURRENCE-ID override (one occurrence moved a day) has no RRULE of
        # its own; it is programming, not a calendar note, and must not be
        # skipped along with the one-offs.
        ics = _ics(_vevent("UID:u1", "SUMMARY:Free Weekend", "DTSTART;VALUE=DATE:20260724",
                           "RRULE:FREQ=WEEKLY;UNTIL=20260731"),
                   _vevent("UID:u1", "SUMMARY:Free Weekend", "DTSTART;VALUE=DATE:20260725",
                           "RECURRENCE-ID;VALUE=DATE:20260724"))
        shows = self._fetch(ics, today=date(2026, 7, 22))
        self.assertEqual(sorted(s["start"] for s in shows), ["2026-07-25", "2026-07-31"])

    def test_recurring_all_day_series_keeps_dtend_as_end(self):
        ics = _ics(_vevent("SUMMARY:Free Weekend", "DTSTART;VALUE=DATE:20260724",
                           "DTEND;VALUE=DATE:20260726", "RRULE:FREQ=WEEKLY;UNTIL=20260731"))
        shows = self._fetch(ics, today=date(2026, 7, 22))
        self.assertEqual([(s["start"], s["end"]) for s in shows],
                         [("2026-07-24", "2026-07-25"), ("2026-07-31", "2026-08-01")])

    def test_valarm_description_does_not_overwrite_the_events(self):
        ics = _vevent("SUMMARY:Jam", "DTSTART:20260701T190000", "DESCRIPTION:Real copy",
                      "BEGIN:VALARM", "DESCRIPTION:Reminder", "SUMMARY:Alarm", "END:VALARM")
        (ev,) = playground._events(ics)
        self.assertEqual(ev["description"], "Real copy")
        self.assertEqual(ev["summary"], "Jam")

    def test_tzid_parameter_is_honoured(self):
        ics = _ics(_vevent("SUMMARY:Touring", "DTSTART;TZID=America/New_York:20260701T200000"))
        (s,) = self._fetch(ics)
        self.assertEqual(s["start"], "2026-07-01T19:00:00")   # 8 PM ET → 7 PM CT

    def test_unknown_tzid_is_logged_and_read_as_chicago(self):
        ics = _ics(_vevent("SUMMARY:Odd", "DTSTART;TZID=Mars/Olympus:20260701T200000"))
        with self.assertLogs("ucb.playground", level="WARNING"):
            (s,) = self._fetch(ics)
        self.assertEqual(s["start"], "2026-07-01T20:00:00")

    def test_html_entities_in_descriptions_are_unescaped(self):
        ics = _ics(_vevent("SUMMARY:Jam", "DTSTART:20260701T190000",
                           "DESCRIPTION:Tom &amp; Jerry&#39;s <b>jam</b>"))
        (s,) = self._fetch(ics)
        self.assertEqual(s["description"], "Tom & Jerry's jam")


# ---- Magnet ---------------------------------------------------------------

def _magnet_card(href: str, ctype: str, starts: str, ends: str, status: str = "Open") -> str:
    link = f'<a href="{href}">' if href is not None else "<a>"
    return f"""
    <div class="class-holder">
      <div class="instructor"><a>Jane Doe</a></div>
      <div class="details">
        <strong>{link}{ctype}</a></strong><br>
        Mondays 7pm - 10pm (in-person)<br>
        Starts:<br>
        {starts}<br>
        Ends:<br>
        {ends}<br>
        {status}
      </div>
    </div>"""


class MagnetCalendarTests(unittest.TestCase):
    def test_relative_href_and_hour_only_time(self):
        html = """<table><tr><td><strong class="date">19</strong>
          <div class="an-event"><a href="/show/456/"><p class="summary">Late Jam</p></a>
          <span class="time">8pm - Free</span></div></td></tr></table>"""
        (s,) = magnet._parse_month(html, 2026, 6)
        self.assertEqual(s["url"], "https://magnettheater.com/show/456/")
        self.assertEqual(s["slug"], "456")
        self.assertEqual(s["start"], "2026-06-19T20:00:00")
        self.assertTrue(s["has_time"])
        self.assertTrue(s["is_free"])


class MagnetDetailTests(unittest.TestCase):
    _PAGE = """<html><head><meta property="og:image" content="https://magnettheater.com/x.jpg"></head>
      <body><div id="content"><h2>About the Show</h2>{copy}
      <p>Magnet Theater 254 West 29th St. New York NY 10001</p>
      <table><tr><td>Tickets</td><td>Megawatt</td><td>Sep 9 8pm</td><td>$10</td><td>Buy Ticket</td></tr>
      <tr><td>Megawatt</td><td>Sep 16 8pm</td><td>$10</td><td>Buy Ticket</td></tr></table>
      </div></body></html>"""

    def _detail(self, copy):
        with patch.object(magnet, "fetch_html", return_value=self._PAGE.format(copy=copy)):
            return magnet.detail("https://magnettheater.com/show/123/")

    def test_content_fallback_is_cut_before_address_and_ticket_table(self):
        desc, _, image, _ = self._detail("<p>Megawatt is Magnet's flagship show.</p>")
        self.assertEqual(desc, "Megawatt is Magnet's flagship show.")
        self.assertEqual(image, "https://magnettheater.com/x.jpg")

    def test_itemprop_description_is_preferred(self):
        desc, *_ = self._detail('<p itemprop="description">Only the copy.</p><p>Other #content noise</p>')
        self.assertEqual(desc, "Only the copy.")

    def test_tickets_mention_without_buy_link_is_kept(self):
        desc, *_ = self._detail("<p>Tickets are cheap at the door.</p><p>Fun.</p>")
        self.assertEqual(desc, "Tickets are cheap at the door. Fun.")
        # Same copy with the address line gone: the cut falls on the table's
        # own "Tickets" header, not the copy's opening word.
        page = self._PAGE.replace("<p>Magnet Theater 254 West 29th St. New York NY 10001</p>", "")
        with patch.object(magnet, "fetch_html",
                          return_value=page.format(copy="<p>Tickets are cheap at the door.</p><p>Fun.</p>")):
            desc, *_ = magnet.detail("https://magnettheater.com/show/123/")
        self.assertEqual(desc, "Tickets are cheap at the door. Fun.")


class MagnetClassTests(unittest.TestCase):
    def test_class_discipline_only_strips_a_numbered_level(self):
        self.assertEqual(magnet._class_discipline("Improv Level Two Intensive"), "Improv")
        self.assertEqual(magnet._class_discipline("Musical Improv L1"), "Musical Improv")
        self.assertEqual(magnet._class_discipline("Sketch Writing Level 3"), "Sketch Writing")
        self.assertEqual(magnet._class_discipline("Next Level Improv"), "Next Level Improv")

    def test_stale_card_is_not_redated_into_next_year(self):
        # A card left up from last winter reads as this year's (and ages out);
        # the year-boundary cases in test_sources_offline still hold.
        self.assertEqual(magnet._infer_date("March 1st", date(2026, 9, 7)), date(2026, 3, 1))
        index = f"<html>{_magnet_card('7', 'Improv Level One', 'January 5th', 'March 1st')}</html>"
        with patch.object(magnet, "fetch_html", return_value=index):
            self.assertEqual(magnet.fetch_classes(date(2026, 9, 7)), [])

    def test_hrefless_card_is_skipped(self):
        index = f"""<html>{_magnet_card(None, 'Improv Level One', 'October 5th', 'December 1st')}
                     {_magnet_card('9', 'Improv Level Two', 'October 5th', 'December 1st')}</html>"""
        with patch.object(magnet, "fetch_html", return_value=index):
            classes = magnet.fetch_classes(date(2026, 9, 7))
        self.assertEqual([c["id"] for c in classes], ["magnet/9"])


# ---- Annoyance ------------------------------------------------------------

def _ld(obj) -> str:
    return f'<html><script type="application/ld+json">{json.dumps(obj)}</script></html>'


class AnnoyanceTests(unittest.TestCase):
    def test_event_ld_accepts_subtypes_and_lists(self):
        self.assertIsNotNone(annoyance._event_ld(_ld({"@type": "TheaterEvent"})))
        self.assertIsNotNone(annoyance._event_ld(_ld({"@type": ["Thing", "ComedyEvent"]})))
        self.assertIsNone(annoyance._event_ld(_ld({"@type": "Organization"})))

    def test_excerpt_cuts_at_a_word(self):
        text = "abcdefghij " * 30
        ex = annoyance._excerpt(text)
        self.assertEqual(ex, ("abcdefghij " * 21).strip())
        self.assertEqual(annoyance._excerpt("short"), "short")

    def test_fetch_defaults_and_odd_ids(self):
        # ids mix int/str, a picture may be a non-string, and a production whose
        # meta fetch failed publishes under the same venue label as the rest.
        perfs = [
            {"event_id": 7, "start": "2026-09-10 20:00", "title": "Meta OK", "picture": {"oops": 1}},
            {"event_id": "8", "start": "2026-09-11 20:00", "title": "No Meta", "picture": None},
        ]
        meta7 = _ld({"@type": "TheaterEvent", "location": {"name": "Annoyance Theatre"},
                     "description": "<p>" + "word " * 80 + "</p>", "image": "https://a.test/7.jpg"})

        def fake(url):
            if "/reports/calendar" in url:
                return json.dumps(perfs)
            if url.endswith("/events/7"):
                return meta7
            raise RuntimeError("429")
        with patch.object(annoyance, "fetch_html", side_effect=fake):
            shows = annoyance.fetch(date(2026, 9, 7))
        by_title = {s["title"]: s for s in shows}
        self.assertEqual(by_title["Meta OK"]["venue"], "Annoyance Theatre")
        self.assertEqual(by_title["No Meta"]["venue"], "Annoyance Theatre")
        self.assertIsNone(by_title["No Meta"]["image"])
        self.assertEqual(by_title["Meta OK"]["image"], "https://a.test/7.jpg")
        self.assertFalse(by_title["Meta OK"]["excerpt"].endswith(" "))
        self.assertLessEqual(len(by_title["Meta OK"]["excerpt"]), 240)


# ---- Brooklyn Comedy Collective -------------------------------------------

def _ny_ms(y, m, d, h) -> int:
    return int(datetime(y, m, d, h, tzinfo=ZoneInfo("America/New_York")).timestamp() * 1000)


class BrooklynCCShowTests(unittest.TestCase):
    def test_closure_notices_skipped_and_rooms_are_venues(self):
        items = [
            {"title": "No Shows - Labor Day Weekend", "startDate": _ny_ms(2026, 9, 4, 19),
             "endDate": _ny_ms(2026, 9, 6, 23), "fullUrl": "/show-schedule/no-shows"},
            {"title": "Big Show", "categories": ["Eris Deep Space"], "startDate": _ny_ms(2026, 9, 10, 20),
             "assetUrl": "https://img.test/x.jpg", "fullUrl": "/show-schedule/big-show"},
            {"title": "Plain Show", "startDate": _ny_ms(2026, 9, 11, 20), "fullUrl": "/show-schedule/plain"},
        ]
        with patch.object(brooklyn_cc, "fetch_json", return_value={"upcoming": items}):
            shows = brooklyn_cc.fetch()
        self.assertEqual([s["title"] for s in shows], ["Big Show", "Plain Show"])
        self.assertEqual(shows[0]["venue"], "Eris Deep Space")
        self.assertEqual(shows[0]["venues"], ["Eris Deep Space"])
        self.assertEqual(shows[0]["comedy_types"], [])
        self.assertEqual(shows[1]["venue"], "Brooklyn Comedy Collective")


class BrooklynCCClassTests(unittest.TestCase):
    def test_instructor_anchored_on_w_slash(self):
        self.assertEqual(brooklyn_cc._class_instructor("Improv 101 w/ Jane Doe (Aug-Oct '26)"), "Jane Doe")
        self.assertEqual(brooklyn_cc._class_instructor("w/ Jane"), "Jane")
        self.assertEqual(brooklyn_cc._class_instructor("Sketch Show/Workshop (Aug '26)"), "")

    def test_class_start_parsed_from_dated_titles_only(self):
        self.assertEqual(brooklyn_cc._class_start("Drop-In Improv (Saturday, September 12th, 2026)"),
                         "2026-09-12")
        self.assertEqual(brooklyn_cc._class_start("FAD Workshop (Oct 3, 2026)"), "2026-10-03")
        self.assertIsNone(brooklyn_cc._class_start("Improv 201 w/ X (Aug-Oct '26)"))

    def test_fetch_classes_sets_image_and_start(self):
        page = '<a href="https://www.brooklyncc.com/class-registration/drop-in">x</a>'
        coll = {"items": [{"fullUrl": "/class-registration/drop-in",
                           "title": "Drop-In Improv w/ Jane Doe (Saturday, September 12th, 2026)",
                           "assetUrl": "https://img.test/c.jpg", "body": "<p>Come play.</p>",
                           "variants": [{"priceMoney": {"value": "25.00"}, "unlimited": True}]}]}
        with patch.object(brooklyn_cc, "fetch_html", return_value=page), \
             patch.object(brooklyn_cc, "fetch_json", return_value=coll):
            (c,) = brooklyn_cc.fetch_classes()
        self.assertEqual(c["id"], "brooklyn_cc/drop-in")
        self.assertEqual(c["image"], "https://img.test/c.jpg")
        self.assertEqual(c["start"], "2026-09-12")
        self.assertEqual(c["instructor"], "Jane Doe")
        self.assertEqual(c["price"], "$25.00")


if __name__ == "__main__":
    unittest.main()

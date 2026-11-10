"""Class detail fields of the Crowdwork adapter (The Annoyance, iO Theater,
Logan Square Improv): instructor, schedule, location, price, image and
description, all derived from the classes API. Fixtures are trimmed real API
items (2026-11); no network."""
from __future__ import annotations

import unittest
from datetime import date, datetime
from unittest.mock import patch

from sources import crowdwork

TODAY = date(2026, 11, 10)


def _item(name: str, dates: list[str], **over) -> dict:
    item = {
        "id": 1, "name": name, "status": "active", "recurring": "Weekly",
        "url": "https://www.crowdwork.com/e/" + name.lower().replace(" ", "-")[:20],
        "dates": dates, "next_date": dates[0] if dates else None,
        "img": {"url": "https://cdn.test/imgs/1/Art.png", "large": "https://cdn.test/imgs/1/large_Art.png"},
        "description": {"body": "<div>About the class.</div>"}, "description_short": "About the class.",
        "cost": {"formatted": "$45.00 (includes fees)"},
        "cost_tiers": [{"name": "General", "cost": 4500, "cost_after_fees": 4500}],
        "venue": "", "location": "1501 N. Kingsbury St., Chicago, IL 60642, Chicago, IL 60642",
        "timezone": "Central Time (US & Canada)", "tags": {"public": ["Improv"]}, "badges": {},
    }
    item.update(over)
    return item


def _weekly(first: str, n: int, hhmm: str = "19:00") -> list[str]:
    start = datetime.strptime(first, "%Y-%m-%d").toordinal()
    return [f"{date.fromordinal(start + 7 * i).isoformat()}T{hhmm}:00.000-06:00" for i in range(n)]


def _rows(*items: dict, city: str = "Chicago") -> list[dict]:
    crowdwork._memo.clear()
    with patch.object(crowdwork, "fetch_json", return_value={"data": list(items)}), \
            patch.object(crowdwork, "local_today", return_value=TODAY):
        return crowdwork.fetch_classes("x", "src", "Org", city)


class InstructorTests(unittest.TestCase):
    def test_names_from_title(self):
        for title, want in (
            ("iO Improv Level 1: Mondays from 7-10pm w/ Damian Anaya", "Damian Anaya"),
            ("iO Improv Level 2: Thursdays from 7-10pm w/ Jess Rogers ", "Jess Rogers"),
            ("DROP-IN: Improv with Gretchen Eng", "Gretchen Eng"),
            ("Variety & Alternative Comedy - Saturdays with Danny Wightkin T127", "Danny Wightkin"),
            ("Scene Study with Jane Doe & John Q. Public", "Jane Doe, John Q. Public"),
            ("Working with Emotion w/ Jane Doe", "Jane Doe"),
        ):
            self.assertEqual(crowdwork._instructor(title), want, title)

    def test_never_invents_a_name(self):
        for title in (
            "AP1 - Mondays with TBD T127",
            "AP3 - Mondays withTBD T127",
            'Masterclass: "JTS Brown and Beyond" with 3 SQUARE',
            "Level 5 with class show",
            "Improv with Special Guests",
            "Sketch Writing with The Annoyance",
            "Scene Work with Live Music",
            "Musical Improv with Tuesday Musical Improv",
            "Working with Emotion",
            "Winter One Week Intensive - 2026",
            "",
        ):
            self.assertEqual(crowdwork._instructor(title), "", title)

    def test_row_carries_instructor(self):
        (c,) = _rows(_item("Level 1 w/ Damian Anaya", _weekly("2026-11-16", 2)))
        self.assertEqual(c["instructor"], "Damian Anaya")


class LocationTests(unittest.TestCase):
    def _loc(self, location, venue="", city="Chicago"):
        return crowdwork._location({"location": location}, venue, city)

    def test_duplicated_city_and_state_collapse(self):
        self.assertEqual(
            self._loc("1501 N. Kingsbury St., Chicago, IL 60642, Chicago, IL 60642"),
            "1501 N. Kingsbury St., Chicago, IL 60642")

    def test_room_prefix_becomes_first_part(self):
        self.assertEqual(
            self._loc("Studio A - 1501 N. Kingsbury St., Chicago, IL 60642, Chicago, IL 60642", "Studio A"),
            "Studio A, 1501 N. Kingsbury St., Chicago, IL 60642")
        self.assertEqual(
            self._loc("Logan Square Improv - 2825 W Diversey Ave. Chicago, IL 60647, Chicago, IL 60618",
                      "Logan Square Improv"),
            "Logan Square Improv, 2825 W Diversey Ave. Chicago, IL 60647")

    def test_missing_city_is_filled_from_the_source(self):
        self.assertEqual(self._loc("851 W Belmont Ave, IL"), "851 W Belmont Ave, Chicago, IL")

    def test_plain_or_missing(self):
        self.assertEqual(self._loc("123 Main St, Chicago, IL 60601"), "123 Main St, Chicago, IL 60601")
        self.assertEqual(self._loc(""), "")
        self.assertEqual(self._loc(None), "")
        self.assertEqual(self._loc({"odd": 1}), "")


class ScheduleTests(unittest.TestCase):
    def _schedule(self, dates, **over):
        (c,) = _rows(_item("Class", dates, **over))
        return c

    def test_weekly_run_counts_past_sessions_and_starts_at_the_next(self):
        c = self._schedule(_weekly("2026-10-19", 8))
        self.assertEqual(c["schedule"], "Mondays 7pm · Oct 19 - Dec 7 · 8 sessions")
        self.assertEqual(c["start"], "2026-11-16T19:00:00")

    def test_next_year_and_half_hour(self):
        c = self._schedule(_weekly("2027-01-04", 8, "18:30"))
        self.assertEqual(c["schedule"], "Mondays 6:30pm · Jan 4 - Feb 22, 2027 · 8 sessions")

    def test_run_spanning_two_years(self):
        c = self._schedule(_weekly("2026-12-18", 4, "18:00"))
        self.assertEqual(c["schedule"], "Fridays 6pm · Dec 18, 2026 - Jan 8, 2027 · 4 sessions")

    def test_monthly(self):
        dates = ["2026-12-05T12:00:00.000-06:00", "2027-01-02T12:00:00.000-06:00",
                 "2027-02-06T12:00:00.000-06:00"]
        c = self._schedule(dates, recurring="Monthly")
        self.assertEqual(c["schedule"],
                         "Saturdays 12pm monthly · Dec 5, 2026 - Feb 6, 2027 · 3 sessions")

    def test_consecutive_days(self):
        dates = [f"2026-12-{d}T11:00:00.000-06:00" for d in (14, 15, 16, 17, 18)]
        c = self._schedule(dates, recurring="Daily")
        self.assertEqual(c["schedule"], "Mon-Fri 11am · Dec 14 - Dec 18 · 5 sessions")

    def test_two_unrelated_dates_are_listed(self):
        c = self._schedule(["2026-11-14T12:00:00.000-06:00", "2026-12-15T18:00:00.000-06:00"],
                           recurring="Multiple dates")
        self.assertEqual(c["schedule"], "Sat Nov 14 12pm, Tue Dec 15 6pm")

    def test_many_irregular_dates_fall_back_to_range_and_count(self):
        dates = ["2026-11-14T12:00:00.000-06:00", "2026-11-17T18:00:00.000-06:00",
                 "2026-11-25T18:00:00.000-06:00", "2026-12-15T18:00:00.000-06:00"]
        c = self._schedule(dates)
        self.assertEqual(c["schedule"], "Nov 14 - Dec 15 · 4 sessions")

    def test_single_date_keeps_the_long_form(self):
        c = self._schedule([], next_date="2027-01-06T12:00:00.000-06:00")
        self.assertEqual(c["schedule"], "Wednesday, January 6 @ 12:00 PM")
        self.assertEqual(c["start"], "2027-01-06T12:00:00")

    def test_next_date_already_in_dates_is_not_counted_twice(self):
        dates = _weekly("2026-11-16", 3)
        c = self._schedule(dates, next_date="2026-11-23T19:00:00-06:00")
        self.assertTrue(c["schedule"].endswith("3 sessions"), c["schedule"])

    def test_separately_sold_dates_are_not_a_course(self):
        # A weekly drop-in: `grouped` False, every date its own enrolment.
        c = self._schedule(_weekly("2026-10-02", 39, "18:00"),
                           grouped_dates={"grouped": False, "message": None})
        self.assertEqual(c["schedule"], "Fridays 6pm · Nov 13, 2026 - Jun 25, 2027 · 33 dates")
        self.assertEqual(c["start"], "2026-11-13T18:00:00")
        c = self._schedule(_weekly("2026-10-19", 8), grouped_dates={"grouped": True, "message": " + 7 more"})
        self.assertEqual(c["schedule"], "Mondays 7pm · Oct 19 - Dec 7 · 8 sessions")

    def test_unexpanded_run_still_reports_its_session_count(self):
        # Far-out intensives: `dates` is empty, only "+ 4 more" tells the length.
        c = self._schedule([], next_date="2027-07-12T10:00:00.000-05:00", recurring="Daily",
                           grouped_dates={"grouped": True, "message": " + 4 more"})
        self.assertEqual(c["schedule"], "Monday, July 12 @ 10:00 AM · 5 sessions")
        for odd in (None, "x", {"grouped": True, "message": 4}, {"grouped": False, "message": None}):
            c = self._schedule([], next_date="2027-07-12T10:00:00.000-05:00", grouped_dates=odd)
            self.assertEqual(c["schedule"], "Monday, July 12 @ 10:00 AM", odd)


class PriceTests(unittest.TestCase):
    def _price(self, formatted, tiers):
        return crowdwork._class_price({"cost_tiers": tiers}, formatted)

    def test_single_paid_tier_among_locked_free_ones(self):
        tiers = [{"name": "Intern", "cost": 0, "cost_after_fees": 0},
                 {"name": "General", "cost": 34000, "cost_after_fees": 35850},
                 {"name": "Zelle Payment ", "cost": 34000, "cost_after_fees": 35850}]
        self.assertEqual(self._price("Multiple prices", tiers), "$358.50 (includes fees)")

    def test_range(self):
        tiers = [{"name": "Full Class", "cost": 31000, "cost_after_fees": 31000},
                 {"name": "Early Bird Discount", "cost": 29000, "cost_after_fees": 29000}]
        self.assertEqual(self._price("Multiple prices", tiers), "$290.00 - $310.00 (includes fees)")
        self.assertEqual(self._price("Multiple prices", [{"cost_after_fees": 189217}, {"cost_after_fees": 94676}]),
                         "$946.76 - $1,892.17 (includes fees)")

    def test_part_payment_tier_is_not_a_price(self):
        tiers = [{"name": "Early Bird Pricing (through 3/31/2027)", "cost_after_fees": 178713},
                 {"name": "JCMS", "cost_after_fees": 189217},
                 {"name": "Payment Plan", "cost_after_fees": 94676}]
        self.assertEqual(self._price("Multiple prices", tiers), "$1,787.13 - $1,892.17 (includes fees)")
        self.assertEqual(self._price("Multiple prices", [{"name": None, "cost_after_fees": 4500}]),
                         "$45.00 (includes fees)")

    def test_source_price_is_kept_otherwise(self):
        tiers = [{"name": "General", "cost": 21500, "cost_after_fees": 22276}]
        self.assertEqual(self._price("$222.76 (includes fees)", tiers), "$222.76 (includes fees)")
        self.assertEqual(self._price("Free", [{"cost_after_fees": 0}]), "Free")
        self.assertEqual(self._price("Multiple prices", [{"cost_after_fees": 0}, "odd"]), "Multiple prices")
        self.assertEqual(self._price("Multiple prices", None), "Multiple prices")


class ImageTests(unittest.TestCase):
    def test_site_logo_is_not_class_artwork(self):
        self.assertIsNone(crowdwork._class_image("https://cdn.test/imgs/19074/large_LSI_Logo.png"))
        self.assertIsNone(crowdwork._class_image("https://cdn.test/imgs/19074/LSI_Logo.png"))
        self.assertIsNone(crowdwork._class_image(None))

    def test_artwork_is_kept(self):
        for url in ("https://cdn.test/imgs/1/large_Drop-in.png",
                    "https://cdn.test/imgs/1/large_Annoyance__Summer_Intensive_Circle_Logo.png"):
            self.assertEqual(crowdwork._class_image(url), url)

    def test_show_images_are_untouched(self):
        self.assertEqual(crowdwork._image({"img": {"large": "https://cdn.test/imgs/1/large_LSI_Logo.png"}}),
                         "https://cdn.test/imgs/1/large_LSI_Logo.png")


_IO_BODY = (
    '<div><strong>Session 6 runs from October 19th – December 20th. Please select the start day that '
    'works best for you. </strong><a href="https://crowdwork.com/v/iotheater/classes">View all available '
    'days</a><br></div><div>Level 3 redirects the focus back on to the two person scene.<br><br></div>'
    '<div>Level 3 is an 8-week course that meets once a week for 3&nbsp;hours.<br><br></div>'
    '<div>Convenience fees are added for purchases made via credit card. If you would like to avoid the '
    'fee, please email classes@ioimprov.com<br><br></div><div><strong>Please double check all details '
    'before booking. We do not offer refunds after purchase- no exceptions.<br></strong><br></div>')

_ANNOYANCE_BODY = (
    '<h1>Workshop: Funny Thing with Jeff Quintana</h1><div><br>Improvisers spend so much time searching '
    'for the games. <br>&nbsp;<br><strong>Instructor Bio:<br>Jeff Quintana</strong> is a comedian, '
    'director and educator.</div><div><br>He has taught everywhere.</div><div><br><strong>Schedule:'
    '</strong><br>Saturday 11/14/2026 12-3pm<br>Tuesday 12/15/2026 6-9pm<br><br>Please ignore the below '
    'schedule information as it may not apply to this class/workshop</div>'
    '<ul><li>Bring water</li><li>Wear shoes</li></ul>')


class DescriptionTests(unittest.TestCase):
    def test_paragraphs_kept_and_payment_boilerplate_dropped(self):
        got = crowdwork._class_description({"description": {"body": _IO_BODY}}, "iO Improv Level 3")
        self.assertEqual(got, "Level 3 redirects the focus back on to the two person scene.\n\n"
                              "Level 3 is an 8-week course that meets once a week for 3 hours.")

    def test_title_line_and_teacher_bio_dropped(self):
        got = crowdwork._class_description({"description": {"body": _ANNOYANCE_BODY}},
                                           "Workshop: Funny Thing with Jeff Quintana")
        self.assertEqual(got, "Improvisers spend so much time searching for the games.\n\n"
                              "Schedule:\nSaturday 11/14/2026 12-3pm\nTuesday 12/15/2026 6-9pm\n\n"
                              "• Bring water\n• Wear shoes")

    def test_bio_on_the_heading_line_is_dropped_too(self):
        body = ("<div>What you will learn.</div><div>Instructor Bio: Jane Doe has taught everywhere.</div>"
                "<div>She also tours.</div><div>Prerequisite: None</div>")
        self.assertEqual(crowdwork._class_description({"description": {"body": body}}, "T"),
                         "What you will learn.\n\nPrerequisite: None")

    def test_falls_back_to_the_short_description(self):
        self.assertEqual(crowdwork._class_description({"description_short": "Short &amp; sweet"}, "T"),
                         "Short & sweet")
        only_boilerplate = {"description": {"body": "<div>No refunds.</div>"}, "description_short": "Short"}
        self.assertEqual(crowdwork._class_description(only_boilerplate, "T"), "Short")
        self.assertEqual(crowdwork._class_description({"description": "odd"}, "T"), "")


class RowTests(unittest.TestCase):
    def test_full_row(self):
        item = _item(
            "iO Improv Level 3: Mondays from 7-10pm w/ Matty Vergun", _weekly("2026-10-19", 8),
            description={"body": _IO_BODY}, cost={"formatted": "Multiple prices"},
            cost_tiers=[{"name": "General", "cost": 34000, "cost_after_fees": 35850},
                        {"name": "Scholar", "cost": 0, "cost_after_fees": 0}],
            venue="Studio A",
            location="Studio A - 1501 N. Kingsbury St., Chicago, IL 60642, Chicago, IL 60642")
        (c,) = _rows(item)
        self.assertEqual(c["instructor"], "Matty Vergun")
        self.assertEqual(c["schedule"], "Mondays 7pm · Oct 19 - Dec 7 · 8 sessions")
        self.assertEqual(c["location"], "Studio A, 1501 N. Kingsbury St., Chicago, IL 60642")
        self.assertEqual(c["price"], "$358.50 (includes fees)")
        self.assertEqual(c["image"], "https://cdn.test/imgs/1/large_Art.png")
        self.assertTrue(c["description"].startswith("Level 3 redirects"))
        self.assertNotIn("refund", c["description"])
        self.assertEqual(c["level"], "Improv")
        self.assertFalse(c["is_full"])

    def test_odd_values_do_not_sink_the_source(self):
        odd = _item("Odd", _weekly("2026-11-16", 2), location=None, cost_tiers="x", recurring=None,
                    description=None, description_short=None, img=None, venue=None)
        (c,) = _rows(odd)
        self.assertEqual((c["location"], c["instructor"], c["description"], c["image"]), ("", "", "", None))
        self.assertEqual(c["price"], "$45.00 (includes fees)")


if __name__ == "__main__":
    unittest.main()

"""Class-detail fields (instructor, location, schedule, description) for The
Second City and Brooklyn Comedy Collective. Offline: fixtures are trimmed
copies of the live payloads' shapes (the Second City find-a-class data route,
BCC's Crowdwork class catalog)."""
from __future__ import annotations

import json
import unittest
from datetime import date, datetime
from unittest.mock import patch

from sources import brooklyn_cc, crowdwork, second_city


# ---- The Second City --------------------------------------------------------

def _sc_row(aid="1", name="Improv 1", site="Second City Training Center Chicago"):
    return {
        "activity_name": name, "activity_id": aid, "activity_status": "Open",
        "site_name": site, "default_facilities": "",
        "default_beginning_date": "2027-01-04", "default_ending_date": "2027-02-22",
        "default_pattern_dates": "Monday,12:00 PM,3h", "NUMBEROFSESSIONS": "7",
        "NUMBER_OPEN": "15", "activity_valid_from": "2027-01-04T12:00:00r",
    }


def _sc_node(rows, description="<p>Yes, and.</p>", direction="230 W. North Ave, Chicago, IL"):
    return {
        "title": rows[0]["activity_name"], "uri": "/classes/chicago/improv/x-chi",
        "activenetData": {"activenetData": json.dumps(rows)},
        "classesCategories": {"nodes": [{"name": "Improv"}]},
        "classes": {"flexibleLayout": [{
            "description": description, "price": "395", "direction": direction,
            "imageDesktop": {"mediaItemUrl": "https://sc.test/i.jpg"}}]},
    }


def _sc_fetch(*nodes):
    payload = {"pageProps": {"dehydratedState": {"queries": [
        {"state": {"data": {"classes": {"nodes": list(nodes)}}}}]}}}
    with patch.object(second_city, "fetch_html", return_value='x "buildId":"BID" x'), \
         patch.object(second_city, "fetch_json", return_value=payload):
        return second_city.fetch_classes(date(2026, 11, 10))


_CAETI = (
    "<p>You have just performed the first scenes of your long form, now what?</p>\n"
    "<p>Prerequisite: Some improv experience helpful but not necessary.</p>\n"
    "<p>Chicago native Frank Caeti (last name rhymes with &#8220;Why Sweaty&#8221;) is an actor, "
    "writer and educator.</p>\n<p>He holds a BA and an MFA.</p>\n")
_KUNKEL = (
    "<p>Come chat with writer and comedy craft book author Caitlin Kunkel.</p>\n"
    "<p>Participants will be able to buy Caitlin&#8217;s book on site.</p>\n"
    "<p>ABOUT THE INSTRUCTOR:<br />\nCaitlin Kunkel is a writer, teacher, and speaker.</p>\n"
    "<p>ABOUT THE BOOK:<br />\nInside Jokes is a step-by-step guide.</p>\n")


class SecondCityClassDetailTests(unittest.TestCase):
    def test_location_is_site_street_city(self):
        (c,) = _sc_fetch(_sc_node([_sc_row()]))
        self.assertEqual(c["location"], "Second City Training Center, 230 W. North Ave, Chicago")
        self.assertEqual(c["instructor"], "")   # the core curriculum names no teacher

    def test_location_address_variants(self):
        row, loc = _sc_row(), second_city._class_location
        self.assertEqual(loc(row, {"direction": "230 W North Ave 2nd Floor Chicago IL 60610"}),
                         "Second City Training Center, 230 W North Ave 2nd Floor, Chicago")
        self.assertEqual(loc(row, {"direction": " 230 W North Ave, Chicago, IL 60614"}),
                         "Second City Training Center, 230 W North Ave, Chicago")
        # The page only says "Chicago": the venue is still known from the section.
        self.assertEqual(loc(row, {"direction": "Chicago"}), "Second City Training Center, Chicago")
        self.assertEqual(loc(row, {}), "Second City Training Center, Chicago")
        self.assertEqual(loc({}, {"direction": "230 W. North Ave, Chicago, IL"}),
                         "230 W. North Ave, Chicago")

    def test_location_online_and_unknown(self):
        loc = second_city._class_location
        self.assertEqual(loc(_sc_row(), {"direction": "Virtual"}), "Online")
        self.assertEqual(loc(_sc_row(name="Improv 1 (Online)"), {"direction": "Chicago"}), "Online")
        self.assertEqual(loc({}, {}), "")
        self.assertEqual(loc({}, {"direction": "Chicago"}), "")

    def test_guest_teacher_from_title_and_bio_cut_from_description(self):
        (c,) = _sc_fetch(_sc_node(
            [_sc_row(name="World Building And Connections with Frank Caeti")], _CAETI, "Chicago"))
        self.assertEqual(c["instructor"], "Frank Caeti")
        self.assertEqual(c["description"],
                         "You have just performed the first scenes of your long form, now what?\n\n"
                         "Prerequisite: Some improv experience helpful but not necessary.")

    def test_about_the_instructor_section_removed(self):
        (c,) = _sc_fetch(_sc_node([_sc_row(name="Office Hours with Caitlin Kunkel")], _KUNKEL))
        self.assertEqual(c["instructor"], "Caitlin Kunkel")
        self.assertEqual(c["description"],
                         "Come chat with writer and comedy craft book author Caitlin Kunkel.\n\n"
                         "Participants will be able to buy Caitlin’s book on site.")
        # The heading is cut on a class whose title names nobody, too.
        (c,) = _sc_fetch(_sc_node([_sc_row(name="Chill Comedy Class")], _KUNKEL))
        self.assertEqual(c["instructor"], "")
        self.assertNotIn("ABOUT THE", c["description"])

    def test_title_name_needs_confirmation_in_the_copy(self):
        ins = second_city._class_instructor
        self.assertEqual(ins("Improv with Good Friends", "Bring a friend and play."), "")
        self.assertEqual(ins("Improv 1", "Taught by Second City faculty."), "")
        self.assertEqual(ins("Clown with Jane Q. Doe", "Jane Q. Doe leads this one."), "Jane Q. Doe")
        # "with" mid-title is not a teacher.
        self.assertEqual(ins("Working with Jane Doe Onstage", "Jane Doe"), "")
        # The company is not a teacher, even though the copy always names it.
        self.assertEqual(ins("An Evening with The Second City", "Join The Second City."), "")
        self.assertEqual(ins("Improv with Second City Alumni", "Second City Alumni teach."), "")

    def test_prerequisite_below_the_biography_is_kept(self):
        html = ("<p>Learn the Deconstruction.</p>"
                "<p>David Montgomery is a faculty member at The Second City.</p>"
                "<p>He has directed improv for 20 years.</p>"
                "<p>Prerequisite: Completion of Improv 3</p>")
        self.assertEqual(second_city._class_description(html, "David Montgomery"),
                         "Learn the Deconstruction.\n\nPrerequisite: Completion of Improv 3")

    def test_first_paragraph_naming_the_teacher_is_kept(self):
        html = "<p>Frank Caeti is back with a one-day workshop.</p><p>Bring water.</p>"
        self.assertEqual(second_city._class_description(html, "Frank Caeti"),
                         "Frank Caeti is back with a one-day workshop.\n\nBring water.")

    def test_description_paragraphs_and_non_string_copy(self):
        html = '<div class="ewa-rteLine">One &amp; two.</div>\n<p>&nbsp;</p>\n<p>Three.</p>'
        self.assertEqual(second_city._class_description(html), "One & two.\n\nThree.")
        self.assertEqual(second_city._class_description(None), "")
        self.assertEqual(second_city._class_description(["x"]), "")


# ---- Brooklyn Comedy Collective (Crowdwork) ---------------------------------

_STANDING_NOTE = ("Our classes meet at BCC Dog House, Pig Pen, or Mouse Trap in East Williamsburg, "
                  "Brooklyn. You will receive a welcome email with your room assignment.")

_LEVEL_BODY = (
    "<div>First time taking an improv class? You&#8217;re in the right place.<br><br></div>"
    "<div>This class culminates in a performance for the public.<br><br></div>"
    "<div>7-Week Class: Monday, 7:00 PM - 10:00 PM, January 4th - February 22nd, 2027<br><br></div>"
    "<ul><li>Note: Class may end between 9:30 PM - 10:00 PM depending on the number of enrollments.</li>"
    "<li>This class skips January 18th for MLK Jr. Day.</li></ul>"
    "<div>This class is limited to 16 students.<br><br></div>"
    '<div><a href="https://www.brooklyncc.com/instructors">Teacher: Kenny Park Yi<br></a><br></div>'
    "<div>Bio:<br><br></div><div>Kenny Park Yi is an NYC-based comedian.<br><br></div>"
    "<div><em>Testimonials:<br></em><br></div><blockquote><em>Great teacher!</em></blockquote>")

_DROPIN_BODY = (
    "<div>What happens in a clown class? We play.<br><br></div>"
    "<div>Drop-in Class: Tuesday, November 17th, 7:00 PM - 9:30 PM.<br><br></div>"
    "<div>Where: BCC Pig Pen, Studio B (130 Graham Ave, Brooklyn)<br><br></div>"
    "<div>Teacher: Hannah Mitchell<br><br></div><div>Bio:<br><br></div><div>Hannah is a clown.</div>")


def _weekly(first: datetime, n: int, skip=()):
    out, d = [], first
    while len(out) < n:
        if d.date().isoformat() not in skip:
            out.append(d.strftime("%Y-%m-%dT%H:%M:%S.000-05:00"))
        d = d.fromordinal(d.toordinal() + 7).replace(hour=first.hour, minute=first.minute)
    return out


def _cw(**kw):
    item = {
        "id": 19234, "name": "Improv Level 1: Intro To Improv w/ Kenny Park Yi (Jan-Feb '27) (Monday)",
        "url": "https://www.crowdwork.com/e/improv-level-1-intro-to-improv-w-kenny-park-yi",
        "status": "active", "recurring": "Weekly",
        "dates": _weekly(datetime(2027, 1, 4, 19), 7, skip=("2027-01-18",)),
        "next_date": "2027-01-04T19:00:00.000-05:00",
        "img": {"url": "https://cdn.test/kenny.jpeg", "large": "https://cdn.test/large_kenny.jpeg"},
        "description": {"body": _LEVEL_BODY}, "description_short": "First time taking an improv class?",
        "cost": {"formatted": "$375.00 (includes fees)"},
        "venue": _STANDING_NOTE, "location": _STANDING_NOTE,
        "timezone": "Eastern Time (US & Canada)", "tags": {"public": ["Improv 1"]},
        "badges": {"spots": None, "cost": "$375.00 (includes fees)"},
    }
    item.update(kw)
    return item


def _bcc_fetch(*items, today=date(2026, 11, 10)):
    crowdwork._memo.clear()
    try:
        with patch.object(crowdwork, "fetch_json", return_value={"data": list(items)}) as fj:
            rows = brooklyn_cc.fetch_classes(today)
        return rows, fj
    finally:
        crowdwork._memo.clear()


class BrooklynCCClassDetailTests(unittest.TestCase):
    def test_multi_week_class_row(self):
        (c,), fj = _bcc_fetch(_cw())
        fj.assert_called_once()   # one request, and it is the Crowdwork catalog
        self.assertIn("/brooklyncomedycollective/classes", fj.call_args[0][0])
        self.assertEqual(c["id"], "brooklyn_cc/19234")
        self.assertEqual(c["url"], "https://www.crowdwork.com/e/improv-level-1-intro-to-improv-w-kenny-park-yi")
        self.assertEqual(c["instructor"], "Kenny Park Yi")
        self.assertEqual(c["start"], "2027-01-04T19:00:00")
        self.assertEqual(c["schedule"], "Mondays 7pm-10pm · Jan 4 - Feb 22 · 7 sessions")
        self.assertEqual(c["price"], "$375.00 (includes fees)")
        self.assertEqual(c["level"], "Improv")
        self.assertEqual(c["image"], "https://cdn.test/large_kenny.jpeg")
        self.assertEqual(c["location"], "BCC Dog House, Pig Pen, or Mouse Trap, East Williamsburg, Brooklyn")
        self.assertFalse(c["is_full"])
        self.assertEqual((c["source"], c["org"], c["city"]),
                         ("brooklyn_cc", "Brooklyn Comedy Collective", "New York"))

    def test_description_stops_before_teacher_bio_and_testimonials(self):
        (c,), _ = _bcc_fetch(_cw())
        self.assertEqual(c["description"], "\n\n".join([
            "First time taking an improv class? You’re in the right place.",
            "This class culminates in a performance for the public.",
            "7-Week Class: Monday, 7:00 PM - 10:00 PM, January 4th - February 22nd, 2027",
            "• Note: Class may end between 9:30 PM - 10:00 PM depending on the number of enrollments.\n"
            "• This class skips January 18th for MLK Jr. Day.",
            "This class is limited to 16 students.",
        ]))

    def test_drop_in_row(self):
        (c,), _ = _bcc_fetch(_cw(
            id=19417, name="Drop-In: Intro to Clown Class: Hannah Mitchell (Tuesday, November 17th, 2026)",
            recurring="Once", dates=["2026-11-17T19:00:00.000-05:00"],
            next_date="2026-11-17T19:00:00.000-05:00", description={"body": _DROPIN_BODY},
            venue="BCC Pig Pen, Studio B (130 Graham Ave)", location="BCC Pig Pen, Studio B (130 Graham Ave)",
            badges={"spots": "Sold out", "cost": "$35.00 (includes fees)"}))
        self.assertEqual(c["instructor"], "Hannah Mitchell")   # the title has no "w/"
        self.assertEqual(c["start"], "2026-11-17T19:00:00")
        self.assertEqual(c["schedule"], "Tuesday, Nov 17 · 7pm-9:30pm")
        self.assertEqual(c["location"], "BCC Pig Pen, Studio B, 130 Graham Ave, Brooklyn")
        self.assertEqual(c["level"], "Drop-In")
        self.assertTrue(c["is_full"])
        self.assertTrue(c["description"].endswith("Where: BCC Pig Pen, Studio B (130 Graham Ave, Brooklyn)"))

    def test_location_shapes(self):
        loc = brooklyn_cc._class_location
        self.assertEqual(loc({"location": "137 Montrose Ave, Brooklyn, NY 11206", "venue": ""},
                             "Where: BCC DogHouse, Studio #2 (137 Montrose Ave, Brooklyn)"),
                         "BCC DogHouse, Studio #2, 137 Montrose Ave, Brooklyn")
        # A "Where:" line that names no single room falls back to the listed address.
        self.assertEqual(loc({"location": "137 Montrose Ave, Brooklyn, NY 11206"},
                             "Where: Location will be sent to students in welcome email"),
                         "137 Montrose Ave, Brooklyn")
        self.assertEqual(loc({"location": "BCC Pig Pen Theater (144 Boerum St)"}, ""),
                         "BCC Pig Pen Theater, 144 Boerum St, Brooklyn")
        self.assertEqual(loc({"location": "This class is virtual. More information will be provided "
                                          "in your welcome email."}, ""), "Online")
        self.assertEqual(loc({"name": "[Virtual] Writers Room w/ X", "location": ""}, ""), "Online")
        self.assertEqual(loc({"location": "Details will be emailed to you."}, ""), "")
        self.assertEqual(loc({}, ""), "")

    def test_schedule_shapes(self):
        sched = brooklyn_cc._sessions_schedule
        two_days = [datetime(2026, 11, 7, 11), datetime(2026, 11, 8, 12)]
        self.assertEqual(sched(two_days, "Workshop: Saturday 11:00am-3:00pm. Sunday 12:00pm - 3:00pm"),
                         "Nov 7 - Nov 8 · 2 sessions")
        weekly = [datetime(2027, 1, 9, 15, 30), datetime(2027, 1, 16, 15, 30)]
        # No end time unless the copy's range starts when the sessions do.
        self.assertEqual(sched(weekly, "Class Show: 7:00 PM - 8:00 PM"),
                         "Saturdays 3:30pm · Jan 9 - Jan 16 · 2 sessions")
        self.assertEqual(sched(weekly, "Saturdays, 3:30PM – 6:30 PM EST"),
                         "Saturdays 3:30pm-6:30pm · Jan 9 - Jan 16 · 2 sessions")

    def test_start_is_first_upcoming_session_and_finished_runs_drop(self):
        running = _cw(dates=_weekly(datetime(2026, 10, 19, 19), 7), next_date=None)
        over = _cw(id=2, dates=["2026-11-05T19:00:00.000-05:00"], next_date=None)
        rows, _ = _bcc_fetch(running, over)
        self.assertEqual([c["id"] for c in rows], ["brooklyn_cc/19234"])
        self.assertEqual(rows[0]["start"], "2026-11-16T19:00:00")
        self.assertEqual(rows[0]["schedule"], "Mondays 7pm-10pm · Oct 19 - Nov 30 · 7 sessions")

    def test_undated_listing_stays_undated(self):
        (c,), _ = _bcc_fetch(_cw(dates=[], next_date=None))
        self.assertIsNone(c["start"])
        self.assertEqual(c["schedule"], "Jan-Feb '27 · Monday")
        # ...unless the title itself names the day (the pre-Crowdwork rule).
        (c,), _ = _bcc_fetch(_cw(name="Drop-In Improv w/ Jane Doe (Saturday, December 12th, 2026)",
                                 dates=None, next_date=None, description={"body": "<div>Come play.</div>"}))
        self.assertEqual(c["start"], "2026-12-12")
        self.assertEqual(c["instructor"], "Jane Doe")

    def test_teacher_tbd_and_missing_copy(self):
        (c,), _ = _bcc_fetch(_cw(description={"body": "<div>Sing!</div><div>Teacher: TBD</div>"}))
        self.assertEqual(c["instructor"], "Kenny Park Yi")   # falls back to the title's "w/"
        self.assertEqual(c["description"], "Sing!")
        (c,), _ = _bcc_fetch(_cw(name="Mystery Class", description=None))
        self.assertEqual(c["instructor"], "")
        self.assertEqual(c["description"], "First time taking an improv class?")

    def test_odd_typed_cost_does_not_put_a_non_string_price_in_the_row(self):
        (c,), _ = _bcc_fetch(_cw(cost={"formatted": None}))
        self.assertEqual(c["price"], "")
        (c,), _ = _bcc_fetch(_cw(cost="375"))
        self.assertEqual(c["price"], "")

    def test_inactive_and_malformed_items_skipped(self):
        rows, _ = _bcc_fetch(_cw(status="draft"), "junk", _cw(id=7, name=""), _cw(id=8))
        self.assertEqual([c["id"] for c in rows], ["brooklyn_cc/8"])

    def test_id_survives_a_retitle(self):
        (a,), _ = _bcc_fetch(_cw())
        (b,), _ = _bcc_fetch(_cw(name="Improv Level 1 w/ Kenny Park Yi (Jan-Feb '27) (Mondays)",
                                 url="https://www.crowdwork.com/e/improv-level-1-renamed"))
        self.assertEqual(a["id"], b["id"])

    def test_unexpected_payload_raises(self):
        crowdwork._memo.clear()
        with patch.object(crowdwork, "fetch_json", return_value={"error": "nope"}):
            with self.assertRaises(RuntimeError):
                brooklyn_cc.fetch_classes(date(2026, 11, 10))


if __name__ == "__main__":
    unittest.main()

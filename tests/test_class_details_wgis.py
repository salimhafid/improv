"""WGIS class detail pages (sources/wgis.class_detail), offline.

Fixtures are real /workshop/view/<id> markup trimmed to the parts the parser
reads plus the neighbours it must ignore (teacher photo and biography, the
"How This Works" / refund policy box).
"""
from __future__ import annotations

import unittest
from unittest import mock

from sources import wgis


def _page(description: str, sessions: str, location: str) -> str:
    return f"""<html><head><meta property="og:image" content="https://www.wgimprovschool.com/photos/user_3332.png"></head>
<body><header><p class='p-0 m-0 text-center fw-semibold'>1615 N. Vermont Ave. Los Angeles, CA 90027</p></header>
<main class='py-6'><div class="lg:container">
<div class='row my-5 py-5'><div class='sm:col-6'>
<h2 class='fs-4xl fw-light'>Empathy Driven Improv</h2>
<div id='class_description' style="display:block"><p><b>Class Description:</b></p>{description}<hr></div>
<p>{sessions}</p>
<p><b>Location:</b><br>{location}</p>
<p><a href='/workshop/ical/1810'><i class="bi-calendar-check"></i> Download iCal file</a></p>
<p>Current time zone is: <b>America/Los_Angeles</b>. You can <a class='' href='/you'>set your own time zone</a> if you like.</p>
<div class='card'><div class='card-body'><p id='point' class=''>This workshop has started or is in the past.</p></div></div>
</div>
<div class='sm:col-6 p-12 border bg-light'><figure class="figure">
	<a href='/teachers/view/3332'><img class='img-fluid border figure-img rounded' src='/photos/user_3332.png'></a>
	  <figcaption class="figure-caption"><b>Teacher: <a href='/teachers/view/3332'>Jim Woods</a></b></figcaption>
	</figure>
<p><small><b>About Jim Woods:</b> Jim Woods has an incredible improv resume.</small></p>
</div></div>
<div class="row m-5 justify-content-center"><div class="md:col-8 border border-info p-5 ">
<h2>How This Works</h2>
<ul><li>You'll get an address in your enrollment email. Online classes are on Zoom.</li>
<li><b>REFUND POLICY:</b><ul><li>Starting 24 hours before: No refund</li></ul></li></ul>
</div></div></div></main></body></html>"""


COURSE = _page(
    """<p>Having trouble making choices? Use your gut response &amp; your own "real life".</p>
<p>You&rsquo;ll learn how to:<br />
-Get out of your head<br />
-Collaborate with others</p>
<p>Please note: There will be no class on 10/18</p>""",
    """6 classes<br>
Sun Oct 4 12pm-3pm (LA)<br>
Sun Oct 11 12pm-3pm (LA) (WGIS Studio 1)<br>
Sun Oct 25 12pm-3pm (LA)<br>
Sun Nov 1 12pm-3pm (LA)<br>
Sun Nov 8 12pm-3pm (LA)<br>
Sun Nov 15 12pm-3pm (LA)<br><br>
$240 USD <small>(includes $5 non-refundable fee)</small><br>
Class size: 14""",
    """WGIS Space<br>1615 N. Vermont Ave.<br>LA CA 90027<br>
three doors to the right of the Clubhouse""")

WITH_SHOW_NEXT_YEAR = _page(
    "<p>No experience necessary!</p>",
    """6 classes, 1 show<br>
Mon Jan 4, 2027 7pm-10pm (LA)<br>
Mon Jan 11, 2027 7pm-10pm (LA)<br>
Mon Feb 15, 2027 7pm-10pm (LA)<br>
&nbsp;&nbsp;&nbsp;Show: Thu Feb 18, 2027 6pm-7pm (LA) (WGIS Space)<br><br>
$250 USD <small>(includes $5 non-refundable fee)</small><br>
Class size: 16""",
    "WGIS Studio 1<br>1613 N. Vermont Ave<br>LA CA 90027")

MIXED_DAYS = _page(
    "<p>Get reps! Wednesdays and Thursdays 6pm-8pm. </p>",
    """4 classes, 1 show<br>
Wed Dec 2 6pm-8pm (LA)<br>
Thu Dec 3 6pm-8pm (LA)<br>
Wed Dec 9 6pm-8pm (LA)<br>
Thu Dec 10 6pm-8pm (LA)<br>
&nbsp;&nbsp;&nbsp;Show: Fri Dec 11 6pm-7pm (LA) (WGIS Space)<br><br>
$90 USD<br>
Class size: 18""",
    "WGIS Studio 1<br>1613 N. Vermont Ave<br>LA CA 90027")

DROP_IN_NY = _page(
    "<p>We'll practice figuring out why something was funny.</p>",
    """1 class<br>
Thu Dec 3 7pm-9:30pm (NYC)<br><br>
$80 USD<br>
Class size: 14""",
    "Cre8tive NYC<br>134 w. 29th St. Floor 2<br>NYC NY 10001")

ONLINE = _page(
    "<p>This is a \"lecture\" format. One hour.</p>",
    """4 classes<br>
Tue Nov 24 5pm-7pm (PST)<br>
Tue Dec 1 5pm-7pm (PST)<br>
Tue Dec 8 5pm-7pm (PST)<br>
Tue Dec 15 5pm-7pm (PST)<br><br>
$160 USD <small>(includes $5 non-refundable fee)</small><br>
Class size: 9""",
    "Online")

# An unknown id answers 200 with the campus chooser instead of a class.
GATEWAY = """<html><body><main class='py-6'><div class="lg:container">
<h1 class='fs-6xl fw-light'>Gateway</h1><p>We have three campuses -- YOU MUST CHOOSE:</p>
<a href='/laclasses'>Los Angeles</a><a href='/nycclasses'>NYC</a></div></main></body></html>"""


class ParseClassDetail(unittest.TestCase):
    def test_course_description_location_schedule(self):
        d = wgis._parse_class_detail(COURSE)
        self.assertEqual(d["description"], (
            'Having trouble making choices? Use your gut response & your own "real life".\n\n'
            "You’ll learn how to:\n-Get out of your head\n-Collaborate with others\n\n"
            "Please note: There will be no class on 10/18"))
        self.assertEqual(d["location"], "WGIS Space, 1615 N. Vermont Ave., Los Angeles, CA 90027")
        self.assertEqual(d["schedule"], "Sundays 12pm-3pm PT · Oct 4 - Nov 15 · 6 classes")

    def test_description_stops_before_everything_else(self):
        text = wgis._parse_class_detail(COURSE)["description"]
        for junk in ("Class Description", "6 classes", "$240", "Class size", "Location", "iCal",
                     "time zone", "has started", "Teacher", "incredible improv resume",
                     "How This Works", "REFUND", "<", "&amp;"):
            self.assertNotIn(junk, text)

    def test_only_contract_keys_and_never_the_teacher_photo(self):
        d = wgis._parse_class_detail(COURSE)
        self.assertEqual(set(d), {"description", "location", "schedule"})

    def test_show_line_is_not_a_session_and_year_is_kept(self):
        d = wgis._parse_class_detail(WITH_SHOW_NEXT_YEAR)
        self.assertEqual(d["schedule"], "Mondays 7pm-10pm PT · Jan 4 - Feb 15, 2027 · 6 classes, 1 show")
        self.assertEqual(d["location"], "WGIS Studio 1, 1613 N. Vermont Ave, Los Angeles, CA 90027")

    def test_several_weekdays(self):
        self.assertEqual(wgis._parse_class_detail(MIXED_DAYS)["schedule"],
                         "Wed/Thu 6pm-8pm PT · Dec 2 - Dec 10 · 4 classes, 1 show")

    def test_single_session_new_york(self):
        d = wgis._parse_class_detail(DROP_IN_NY)
        self.assertEqual(d["schedule"], "Thu Dec 3 7pm-9:30pm ET · 1 class")
        self.assertEqual(d["location"], "Cre8tive NYC, 134 w. 29th St. Floor 2, New York, NY 10001")

    def test_online(self):
        d = wgis._parse_class_detail(ONLINE)
        self.assertEqual(d["location"], "Online")
        self.assertEqual(d["schedule"], "Tuesdays 5pm-7pm PT · Nov 24 - Dec 15 · 4 classes")

    def test_missing_parts_are_empty_not_invented(self):
        html = ("<main><div id='class_description'><p><b>Class Description:</b></p><hr></div>"
                "<p>Dates to be announced</p></main>")
        self.assertEqual(wgis._parse_class_detail(html),
                         {"description": "", "location": "", "schedule": ""})

    def test_address_without_a_zip_line_is_kept_whole(self):
        html = _page("<p>Copy.</p>", "1 class<br>Sat Nov 14 10am-12pm (LA)<br>", "The Clubhouse<br>1607 N. Vermont Ave.")
        self.assertEqual(wgis._parse_class_detail(html)["location"], "The Clubhouse, 1607 N. Vermont Ave.")

    def test_location_heading_inside_the_copy_is_not_the_address(self):
        html = _page("<p><b>Location:</b><br>Bring water<br>and shoes</p>",
                     "1 class<br>Sat Nov 14 10am-12pm (LA)<br>", "WGIS Studio 1<br>1613 N. Vermont Ave<br>LA CA 90027")
        d = wgis._parse_class_detail(html)
        self.assertEqual(d["location"], "WGIS Studio 1, 1613 N. Vermont Ave, Los Angeles, CA 90027")
        self.assertEqual(d["description"], "Location:\nBring water\nand shoes")

    def test_non_breaking_spaces_and_crlf_in_the_copy_become_plain_spaces(self):
        html = _page("<p>Already going.&nbsp;Let's play.<br />\r\n-One</p>", "1 class<br>Sat Nov 14 10am-12pm (LA)<br>", "Online")
        self.assertEqual(wgis._parse_class_detail(html)["description"], "Already going. Let's play.\n-One")

    def test_sessions_at_different_hours_state_no_time(self):
        html = _page("<p>Copy.</p>", "2 classes<br>\nSat Dec 5 10am-12pm (LA)<br>\nSat Dec 12 1pm-3pm (LA)<br>", "Online")
        self.assertEqual(wgis._parse_class_detail(html)["schedule"], "Saturdays · Dec 5 - Dec 12 · 2 classes")

    def test_course_running_into_next_year(self):
        html = _page("<p>Copy.</p>", "3 classes<br>\nMon Dec 21 7pm-10pm (LA)<br>\nMon Dec 28 7pm-10pm (LA)<br>\n"
                     "Mon Jan 4, 2027 7pm-10pm (LA)<br>", "Online")
        self.assertEqual(wgis._parse_class_detail(html)["schedule"],
                         "Mondays 7pm-10pm PT · Dec 21 - Jan 4, 2027 · 3 classes")

    def test_not_a_class_page(self):
        self.assertIsNone(wgis._parse_class_detail(GATEWAY))


class ClassDetailFetch(unittest.TestCase):
    URL = "https://www.wgimprovschool.com/workshop/view/1810"

    def test_fetches_the_given_url(self):
        with mock.patch.object(wgis, "fetch_html", return_value=ONLINE) as fetch:
            d = wgis.class_detail(self.URL)
        fetch.assert_called_once_with(self.URL)
        self.assertEqual(d["location"], "Online")

    def test_fetch_failure_is_none(self):
        with mock.patch.object(wgis, "fetch_html", side_effect=RuntimeError("blocked")):
            self.assertIsNone(wgis.class_detail(self.URL))

    def test_listing_parse_is_untouched_by_detail(self):
        # The watcher calls fetch_classes_*: one listing request, no detail pages.
        listing = ("<h4>Drop Ins</h4><div class='row mb-1'><div class='col-3'><a href='/workshop/view/1860'>"
                   "Saturday Drop In</a></div><div class='col-3'>Rachel Van Nes</div>"
                   "<div class='col-3'>Sat Nov 14 10am (LA) 1 class</div><div class='col-3'>$16 USD</div></div>")
        with mock.patch.object(wgis, "fetch_html", return_value=listing) as fetch:
            rows = wgis.fetch_classes_la()
        fetch.assert_called_once_with("https://www.wgimprovschool.com/laclasses")
        self.assertEqual([(r["id"], r["description"], r["location"]) for r in rows],
                         [("wgis_la/1860", "", "")])


if __name__ == "__main__":
    unittest.main()

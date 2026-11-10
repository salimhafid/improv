"""Offline tests for Magnet's per-class page scraper (magnet.class_detail).

The fixture is trimmed real markup from magnettheater.com/class/<listing>/<id>/
(November 2026): the nav column, the header with the class artwork and the
enrollment block, the description, the instructor block with its biography
and headshot, and the session + show schedules. No network.
"""
from __future__ import annotations

import unittest
from unittest.mock import patch

from sources import magnet

URL = "https://magnettheater.com/class/all-classes-in-session/12064/"

_ENROLL = """<div style="font-weight: bold; color: red;">(Full, click button above for Wait List information)</div>Class Days: Thursdays 6pm - 8pm (in-person)<br>Begins: Nov 12, 2026<br>Ends: Jan 21, 2027<br>Price: <span class="price">$299</span>                            <br><br>"""

_DESCRIPTION = """<p>From day one you will jump into a series of fun warm ups &amp; games.</p><p>
Prerequisite: none.<br/><br/>
Applications due: noon on Tue (9/15)</p>"""

_INSTRUCTOR = """<div class="instructor-title panel-header">
                Instructor: <a href="https://magnettheater.com/people/ivy-hong">Ivy Hong</a>
            </div>
            <hr>
            <div class="instructor-bio col-md-12">
                <div class="col-md-3 pull-left">
                    <a href="https://magnettheater.com/people/ivy-hong">
                        <img class="img-circle" src="https://magnettheater.com/wp-content/uploads/2024/03/Ivy-Hong-Headshot.jpg"/>
                    </a>
                </div>
                <p>Ivy has been a teacher at the Magnet since 2021. She lives in Harlem.</p>
            </div>
            <div class="clear"></div>"""


def _session(when: str, venue: str, note: str) -> str:
    return f"""<li>
                        <strong>{when}</strong><br/>
                        at {venue}<br/>
                        ({note})
                    </li>"""


_STUDIO = ("Michael Howard Studios - Studio 3", "152 W. 25th Street, 10th fl")
_SESSIONS = "".join(_session(f"{d}, 6:00pm - 8:00pm", *_STUDIO)
                    for d in ("Nov 12, 2026", "Nov 19, 2026", "Dec 3, 2026"))
_SHOWS = """<h4 class="panel-header" id="show-schedule">Show Schedule*</h4>
                <ol class="schedule">
                    <li><strong>Jan 23, 2027, 6:00 PM</strong><br/>
                        at Magnet Theater<br/>
                        (254 W. 29th Street)</li>
                    <sub>*scheduling subject to change</sub>
                </ol>"""


def _page(enroll: str = _ENROLL, description: str = _DESCRIPTION,
          instructor: str = _INSTRUCTOR, sessions: str = _SESSIONS, shows: str = _SHOWS) -> str:
    return f"""<html><head><meta property="og:image" content="https://magnettheater.com/logo.png"></head><body>
<div id="content">
<div class="class-nav col-md-3 col-sm-4">
  <ul class="class-list first-class">
    <li><img border="0" src="https://magnettheater.com/wp-content/uploads/2018/07/trainingcenter_logo_color_web_trimmed.png"/></li>
  </ul>
  <ul class="class-list"><li class="single-class"><a href="https://magnettheater.com/class/improv-level-one">Improv Level One</a></li></ul>
</div><!-- .class-nav -->
<div class="col-md-9 col-sm-8" id="class-details">
    <div class="class-detail-container panel panel-default">
        <div class="basic-info panel-body">
            <img alt="Improv Level One" src="https://magnettheater.com/wp-content/uploads/2018/06/improv-level-one.jpg"/>
            <br/>
            <h1 class="class-title">
                Improv Level One with Ivy Hong            </h1>
        </div>
        <div class="class-register-container panel-body">
            <a href="/register/12064" class="register-button">Full...</a>
            {enroll}
                <div class="class-disclaimer"><a href="#class-schedule">Check below</a> to see the full schedule for each session, see if your class skips a week for a holiday, and check out the date and time of your class show(s).</div>
        </div>
        <div class="clear"></div>
    </div><!-- .class-detail-container -->
    <div class="description-container panel panel-default">
        <div class="panel-body">
            <h4 class="panel-header">Class Description</h4>
            <hr>
            {description}
        </div>
    </div><!-- .description-container -->
    <div class="instructor-container panel panel-default">
        <div class="panel-body">
            {instructor}
        </div>
    </div><!-- .instructor-container -->
    <div class="panel panel-default" id="class-schedule">
        <div class="panel-body">
            <h4 class="panel-header">Full Session Schedule <i class="fa fa-calendar-alt"></i></h4>
            <hr/>
            <h4 class="panel-header">Session Schedule*</h4>
            <ol class="schedule">
                {sessions}
            </ol>
            {shows}
        </div>
    </div><!-- #class-schedule -->
</div><!-- #class-detail -->
</div></body></html>"""


def _detail(html: str):
    with patch.object(magnet, "fetch_html", return_value=html):
        return magnet.class_detail(URL)


class MagnetClassDetailTests(unittest.TestCase):
    def test_open_class_page(self):
        d = _detail(_page())
        self.assertEqual(d["price"], "$299")
        self.assertEqual(d["location"],
                         "Michael Howard Studios - Studio 3, 152 W. 25th Street, 10th fl, New York")
        self.assertEqual(d["instructor"], "Ivy Hong")
        # The class artwork — not the nav logo, the og:image or the headshot.
        self.assertEqual(d["image"],
                         "https://magnettheater.com/wp-content/uploads/2018/06/improv-level-one.jpg")

    def test_description_is_plain_paragraphs_without_header_or_bio(self):
        d = _detail(_page())
        self.assertEqual(d["description"],
                         "From day one you will jump into a series of fun warm ups & games.\n\n"
                         "Prerequisite: none.\n\n"
                         "Applications due: noon on Tue (9/15)")
        self.assertNotIn("Harlem", d["description"])

    def test_in_session_page_publishes_no_price(self):
        # Once a section has started the enrollment block (days/dates/price) is gone.
        d = _detail(_page(enroll="<br><br>"))
        self.assertNotIn("price", d)
        self.assertTrue(d["description"])
        self.assertTrue(d["location"])

    def test_address_inside_the_venue_line_drops_cross_streets(self):
        sessions = _session("Nov 9, 2026, 6:00pm - 8:00pm",
                            "Ripley Grier (520 8th Ave, 16th fl)", "btw 36th &amp; 37th Sts")
        self.assertEqual(_detail(_page(sessions=sessions))["location"],
                         "Ripley Grier, 520 8th Ave, 16th fl, New York")

    def test_theater_classroom(self):
        sessions = _session("Jan 4, 2027, 11:30am - 3:30pm", "Magnet Theater", "254 W. 29th Street")
        self.assertEqual(_detail(_page(sessions=sessions))["location"],
                         "Magnet Theater, 254 W. 29th Street, New York")

    def test_room_tba_has_no_location_even_with_a_show_at_the_theater(self):
        sessions = _session("Jan 24, 2027, 12:00pm - 3:00pm", "TBA",
                            "at a studio space TBA in the vicinity of Chelsea/Midtown Manhattan")
        self.assertNotIn("location", _detail(_page(sessions=sessions)))

    def test_location_is_where_most_sessions_meet(self):
        sessions = (_session("Nov 12, 2026, 6:00pm - 8:00pm", "Magnet Theater", "254 W. 29th Street")
                    + _SESSIONS)
        self.assertTrue(_detail(_page(sessions=sessions))["location"].startswith("Michael Howard"))

    def test_online_sessions(self):
        sessions = _session("Nov 12, 2026, 6:00pm - 8:00pm", "Online", "Zoom link sent by email")
        self.assertEqual(_detail(_page(sessions=sessions))["location"], "Online")

    def test_two_instructors(self):
        second = _INSTRUCTOR.replace("ivy-hong", "sam-roe").replace(">Ivy Hong<", ">Sam Roe<")
        d = _detail(_page(instructor=_INSTRUCTOR + second))
        self.assertEqual(d["instructor"], "Ivy Hong, Sam Roe")

    def test_applications_closed_sign_is_not_artwork(self):
        # Application-only sections show this sign where the artwork goes.
        sign = "https://magnettheater.com/wp-content/uploads/2026/02/Screenshot-2026-02-09-at-11.09.54-AM.png"
        html = _page().replace(
            "https://magnettheater.com/wp-content/uploads/2018/06/improv-level-one.jpg", sign)
        self.assertIn(sign, html)
        d = _detail(html)
        self.assertNotIn("image", d)
        self.assertTrue(d["description"])

    def test_non_class_page_is_none(self):
        # An unknown id serves the discipline listing: no #class-details block.
        listing = """<html><body><div id="content"><h1>Improv Level One Classes</h1>
            <div class="class-holder"><div class="details"><strong><a href="12064">Improv Level One</a>
            </strong></div></div></div></body></html>"""
        self.assertIsNone(_detail(listing))

    def test_failed_fetch_is_none(self):
        with patch.object(magnet, "fetch_html", side_effect=RuntimeError("blocked")):
            self.assertIsNone(magnet.class_detail(URL))


if __name__ == "__main__":
    unittest.main()

"""UCB class details (description, full schedule line, location) from Arlo.

Fixtures are trimmed real eventsearch markup; no network.
"""
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from sources import ucb_classes

_14TH = {"VenueID": 16, "Name": "NY: 14th Street Campus", "VenueName": "14th Street Campus",
         "VenueRoomName": "Upstairs Stage (242)", "StreetLine1": "239 E 14th Street",
         "City": "New York City", "State": "NY", "Country": "United States", "PostCode": "10003"}
_UNION_SQ = {"VenueID": 25, "Name": "NY: Union Square", "VenueName": "Union Square",
             "VenueRoomName": "Room 3", "StreetLine1": "113 University Place",
             "StreetLine2": "Sixth Floor", "City": "New York", "State": "NY",
             "Country": "United States", "PostCode": "10003"}
_ZOOM = {"VenueID": 7, "Name": "Online", "VenueName": "UCB Zoom Room", "City": "Online",
         "Country": "United States"}


def _session(name, start, end, location):
    return {"Name": name, "StartDateTime": start, "EndDateTime": end, "Location": location}


def _event(eid=42621, **changes):
    """Improv 201 at Union Square: 8 weekly sessions and a class show at 14th St."""
    weeks = ["2026-11-11", "2026-11-18", "2026-12-02", "2026-12-09",
             "2026-12-16", "2027-01-06", "2027-01-13", "2027-01-20"]
    sessions = [_session(f"Session {i}", f"{day}T19:00:00.0000000-05:00",
                         f"{day}T22:00:00.0000000-05:00", _UNION_SQ)
                for i, day in enumerate(weeks, 1)]
    sessions.append(_session("Class Show", "2027-01-24T15:00:00.0000000-05:00",
                             "2027-01-24T16:00:00.0000000-05:00", _14TH))
    event = {
        "EventID": eid, "Name": "Improv 201",
        "ViewUri": "https://ucbcomedy.com/?object_post_type=event&arlo_id=42",
        "StartDateTime": "2026-11-11T19:00:00.0000000-05:00",
        "EndDateTime": "2027-01-24T16:00:00.0000000-05:00",
        "Summary": "Category: Improv &amp; Musical Improv",
        "SessionsDescription": "Wednesdays 7pm-10pm ET",
        "Description": {"ContentType": "application/xhtml", "Text": (
            "<p><span>Build on Improv 101 with the\nGame of the Scene.&nbsp;</span></p>\n"
            "<p>&nbsp;</p>\n"
            "<p><em>Course meets for 8 sessions.<br>There is a class performance.</em></p>")},
        "Location": {"Name": "NY: Union Square"}, "Tags": ["LOC_NY", "CTG_Improv"],
        "Categories": [{"Name": "1. Improv"}], "Presenters": [{"Name": "Doug Moe"}],
        "AdvertisedOffers": [{"OfferAmount": {"FormattedAmountTaxInclusive": "$475.00"}}],
        "IsFull": False, "Sessions": sessions,
    }
    event.update(changes)
    return event


class UcbClassDetailTests(unittest.TestCase):
    def setUp(self):
        ucb_classes._memo = None
        self.addCleanup(setattr, ucb_classes, "_memo", None)

    def _rows(self, *events, fetch=ucb_classes.fetch_ny):
        with patch.object(ucb_classes, "fetch_json", return_value={"Items": list(events)}):
            return fetch()

    def test_row_carries_description_schedule_and_location(self):
        (row,) = self._rows(_event())
        self.assertEqual(row["description"],
                         "Build on Improv 101 with the Game of the Scene.\n\n"
                         "Course meets for 8 sessions.\nThere is a class performance.")
        self.assertEqual(row["schedule"],
                         "Wednesdays 7pm-10pm ET · Nov 11 - Jan 24 · 8 sessions + class show")
        # Where the class meets, not the stage of its one class show.
        self.assertEqual(row["location"], "Union Square, 113 University Place, Sixth Floor, New York")
        self.assertEqual(row["start"], "2026-11-11T19:00:00")
        self.assertEqual((row["instructor"], row["price"], row["level"]),
                         ("Doug Moe", "$475.00", "Improv"))

    def test_teacher_biography_is_dropped(self):
        bio_by_name = _event(Presenters=[{"Name": "Greg Stees"}], Description={"Text": (
            "<div>A one-day intensive for directors.</div><div>&nbsp;</div>"
            "<div><span>Greg Stees is a filmmaker and editor.</span></div>")})
        bio_by_label = _event(43304, Description={"Text": (
            "<p>A workshop on strong choices.</p>"
            "<p>INSTRUCTOR BIO: Carolyn currently teaches improv at UCB NY.</p>")})
        named_in_copy = _event(43905, Presenters=[{"Name": "John Milhiser"}], Description={"Text": (
            "<p>Physicality in Characters with John Milhiser is here to help you.</p>")})
        rows = {r["id"]: r["description"] for r in self._rows(bio_by_name, bio_by_label, named_in_copy)}
        self.assertEqual(rows["ucb_ny/42621"], "A one-day intensive for directors.")
        self.assertEqual(rows["ucb_ny/43304"], "A workshop on strong choices.")
        self.assertEqual(rows["ucb_ny/43905"],
                         "Physicality in Characters with John Milhiser is here to help you.")

    def test_hard_wrapped_copy_is_rejoined_but_lists_keep_their_lines(self):
        wrapped = _event(Description={"Text": (
            "<p><span>From edgy adult series like “Rick &amp; Morty” and “Primal” to</span><br>"
            "<span>groundbreaking family shows like “Bluey” and “Infinity Train,”</span><br>"
            "<span>animation on television is a varied landscape!</span><br><br>"
            "<span>Along the way students will learn the fundamentals of how these shows</span><br>"
            "<span>are created.</span></p>")})
        listed = _event(2, Description={"Text": (
            "<p>Students learn how to<br>1) Perform openings<br>2) Create scenes<br>"
            "agreement<br>active listening</p>"
            "<p>Please note:<br>Students will be expected to write and prepare characters "
            "outside of class.<br>you will perform them!</p>")})
        rows = [r["description"] for r in self._rows(wrapped, listed)]
        self.assertEqual(rows[0], (
            "From edgy adult series like “Rick & Morty” and “Primal” to groundbreaking family "
            "shows like “Bluey” and “Infinity Train,” animation on television is a varied landscape!"
            "\n\nAlong the way students will learn the fundamentals of how these shows are created."))
        self.assertEqual(rows[1], (
            "Students learn how to\n1) Perform openings\n2) Create scenes\nagreement\nactive listening"
            "\n\nPlease note:\nStudents will be expected to write and prepare characters "
            "outside of class.\nyou will perform them!"))

    def test_summary_stands_in_only_without_a_description(self):
        rows = self._rows(
            _event(1, Description=None, Summary="Learning Narrative Musical Structure"),
            _event(2, Description={"Text": "<p>&nbsp;</p>"}, Summary="“Category: Featured Programs”"),
            _event(3, Summary="Sketch Comedy Writing"))
        self.assertEqual([r["description"] for r in rows], [
            "Learning Narrative Musical Structure", "",
            "Build on Improv 101 with the Game of the Scene.\n\n"
            "Course meets for 8 sessions.\nThere is a class performance."])

    def test_one_off_workshop_keeps_the_first_session_line(self):
        one = _session(None, "2026-11-12T19:00:00.0000000-05:00",
                       "2026-11-12T22:00:00.0000000-05:00", dict(_UNION_SQ, VenueRoomName="Room 5"))
        (row,) = self._rows(_event(
            SessionsDescription=None, Sessions=[one],
            StartDateTime=one["StartDateTime"], EndDateTime=one["EndDateTime"]))
        self.assertEqual(row["schedule"], "Thursday, November 12 @ 7:00 PM - 10:00 PM")
        self.assertEqual(row["location"], "Union Square, 113 University Place, Sixth Floor, New York")

    def test_schedule_variants(self):
        base = _event()
        cases = [
            # A one-day class with a pattern: its date, no session count.
            ({"SessionsDescription": "Sunday 10:30am-6:30pm PT", "Sessions": base["Sessions"][:1],
              "EndDateTime": "2026-11-11T22:00:00.0000000-05:00"},
             "Sunday 10:30am-6:30pm PT · Nov 11"),
            # Arlo's own stray label and padding are not part of the pattern.
            ({"SessionsDescription": " Duration Tuesdays 12pm-3pm ET", "Sessions": base["Sessions"][:8]},
             "Tuesdays 12pm-3pm ET · Nov 11 - Jan 24 · 8 sessions"),
            # A tech rehearsal is not a class meeting either.
            ({"Sessions": base["Sessions"] + [_session(
                "Tech Rehearsal", "2027-01-24T13:00:00.0000000-05:00",
                "2027-01-24T14:30:00.0000000-05:00", _14TH)]},
             "Wednesdays 7pm-10pm ET · Nov 11 - Jan 24 · 8 sessions + class show"),
            # Sessions missing (not expanded / empty): pattern and dates only.
            ({"Sessions": None}, "Wednesdays 7pm-10pm ET · Nov 11 - Jan 24"),
            # Nothing but a start: exactly the line published before.
            ({"Sessions": None, "SessionsDescription": None, "EndDateTime": None},
             "Wednesday, November 11 @ 7:00 PM"),
            ({"StartDateTime": None}, "Wednesdays 7pm-10pm ET · 8 sessions + class show"),
        ]
        for changes, expected in cases:
            with self.subTest(changes=sorted(changes)):
                ucb_classes._memo = None
                (row,) = self._rows(_event(**changes))
                self.assertEqual(row["schedule"], expected)

    def test_location_variants(self):
        show_only_elsewhere = _event()["Sessions"]
        cases = [
            # No sessions: the event's own Location when it carries an address...
            ({"Sessions": [], "Location": _14TH}, "14th Street Campus, 239 E 14th Street, New York City"),
            # ...but a bare campus label is not an address.
            ({"Sessions": []}, ""),
            ({"Sessions": [dict(s, Location=_ZOOM) for s in show_only_elsewhere]}, "Online"),
            ({"Sessions": [{"Name": "Session 1"}, "junk"], "Location": None}, ""),
        ]
        for changes, expected in cases:
            with self.subTest(expected=expected):
                ucb_classes._memo = None
                (row,) = self._rows(_event(**changes))
                self.assertEqual(row["location"], expected)

    def test_online_classes_are_located_online(self):
        online = _event(Tags=["LOC_Online"], Location={"Name": "Online"},
                        Sessions=[dict(s, Location=_ZOOM) for s in _event()["Sessions"]])
        (row,) = self._rows(online, fetch=ucb_classes.fetch_online)
        self.assertEqual(row["location"], "Online")
        # A hybrid listing is "Online" in the online feed whatever its venue.
        (row,) = self._rows(_event(Tags=["LOC_NY", "LOC_Online"]), fetch=ucb_classes.fetch_online)
        self.assertEqual(row["location"], "Online")

    def test_feed_and_watcher_requests_are_separate_single_walks(self):
        page = {"Items": [_event()]}
        with patch.object(ucb_classes, "fetch_json", return_value=page) as fetch:
            ucb_classes.fetch_ny(), ucb_classes.fetch_la(), ucb_classes.fetch_online()
            self.assertEqual(fetch.call_count, 1)      # three feed passes, one walk
            feed = parse_qs(urlsplit(fetch.call_args.args[0]).query)
            ucb_classes.raw_events(), ucb_classes.raw_events()
            self.assertEqual(fetch.call_count, 2)      # the watcher's own, memoised
            watcher = parse_qs(urlsplit(fetch.call_args.args[0]).query)
        for name in ("Description", "SessionsDescription", "EndDateTime", "Sessions"):
            self.assertIn(name, feed["fields"][0].split(","))
        self.assertIn("Sessions", feed["expand"][0].split(","))
        # The ~2-minute watcher poll is byte-for-byte the request it always was.
        self.assertEqual(watcher["fields"], [
            "EventID,ViewUri,Name,StartDateTime,Summary,IsFull,Location,"
            "Categories,Tags,Presenters,AdvertisedOffers"])
        self.assertEqual(watcher["expand"], ["Categories,Presenters,AdvertisedOffers,Location"])

    def test_failed_watcher_walk_does_not_poison_the_feed_walk(self):
        with patch.object(ucb_classes, "fetch_json", side_effect=RuntimeError("arlo down")) as fetch:
            for _ in range(2):
                with self.assertRaises(RuntimeError):
                    ucb_classes.raw_events()
            self.assertEqual(fetch.call_count, 1)
        (row,) = self._rows(_event())
        self.assertEqual(row["id"], "ucb_ny/42621")


if __name__ == "__main__":
    unittest.main()

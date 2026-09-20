"""Public Arlo venue metadata must route sessions before LOC tags arrive."""
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from sources import ucb_classes


def event(event_id, location, tags=None):
    result = {
        "EventID": event_id, "Name": "A new workshop",
        "ViewUri": "https://ucbcomedy.com/?arlo_id=353",
        "Location": location, "StartDateTime": "2026-09-30T11:00:00-04:00",
    }
    if tags is not None:
        result["Tags"] = tags
    return result


class UcbClassLocationTests(unittest.TestCase):
    def setUp(self):
        ucb_classes._memo = None
        self.addCleanup(setattr, ucb_classes, "_memo", None)

    def test_routes_untagged_published_sessions_in_all_three_feeds(self):
        # Arlo commonly supplies just Name, even when Location is expanded.
        page = {"Items": [
            event(42589, {"Name": "NY: 14th Street Campus"}, ["CTG_Clowning"]),
            event(42590, {"Name": "LA: Franklin Campus"}, []),
            event(41946, {"Name": "Online"}),
        ]}
        with patch.object(ucb_classes, "fetch_json", return_value=page) as fetch:
            feeds = [ucb_classes.fetch_ny(), ucb_classes.fetch_la(), ucb_classes.fetch_online()]
        self.assertEqual([[c["id"] for c in feed] for feed in feeds],
                         [["ucb_ny/42589"], ["ucb_la/42590"], ["ucb_online/41946"]])
        self.assertEqual(fetch.call_count, 1)
        query = parse_qs(urlsplit(fetch.call_args.args[0]).query)
        self.assertIn("Location", query["fields"][0].split(","))
        self.assertIn("Location", query["expand"][0].split(","))

    def test_expanded_location_fields_support_unlabelled_venues(self):
        cases = [
            ({"City": "New York City", "Country": "United States"}, "LOC_NY"),
            ({"City": "New York", "Country": "US"}, "LOC_NY"),
            ({"City": "Los Angeles", "Country": "United States"}, "LOC_LA"),
            ({"IsOnline": True, "Name": "Virtual classroom"}, "LOC_Online"),
            ({"Name": "  online  "}, "LOC_Online"),
        ]
        for location, tag in cases:
            with self.subTest(location=location):
                self.assertEqual(ucb_classes.event_location_tags(event(1, location)), [tag])

    def test_explicit_tags_take_precedence_over_conflicting_venue(self):
        self.assertEqual(ucb_classes.event_location_tags(
            event(1, {"Name": "Online"}, ["LOC_NY"])), ["LOC_NY"])
        self.assertEqual(ucb_classes.event_location_tags(
            event(1, {"Name": "NY: Union Square"}, ["LOC_LA", "LOC_Online"])),
            ["LOC_LA", "LOC_Online"])

    def test_unsupported_explicit_location_is_not_reassigned(self):
        for tag in ("LOC_TX", "LOC_PIT", "LOC_Edinburgh"):
            with self.subTest(tag=tag):
                self.assertEqual(ucb_classes.event_location_tags(
                    event(1, {"Name": "Online"}, [tag])), [])

    def test_ambiguous_locations_stay_unassigned_despite_title(self):
        for location in (None, {}, "Online", {"Name": "New York style comedy"},
                         {"Name": "Brooklyn"}, {"City": "Albany", "State": "NY"},
                         {"City": "Los Angeles", "Country": "Chile"},
                         {"Name": "Virtual classroom", "IsOnline": "true"}):
            with self.subTest(location=location):
                e = event(1, location)
                e["Name"] = "ONLINE workshop in New York and LA"
                self.assertEqual(ucb_classes.event_location_tags(e), [])

    def test_unassigned_diagnostic_is_emitted_once_per_walk(self):
        unknown = event(999, {"Name": "Mystery campus"})
        unsupported = event(998, {"Name": "Austin: ColdTowne Theater"}, ["LOC_TX"])
        with patch.object(ucb_classes, "fetch_json", return_value={"Items": [unknown, unsupported]}):
            with self.assertLogs("ucb.classes.source", level="WARNING") as logs:
                self.assertEqual(ucb_classes.fetch_ny(), [])
                self.assertEqual(ucb_classes.fetch_la(), [])
                self.assertEqual(ucb_classes.fetch_online(), [])
        self.assertEqual(len(logs.output), 1)
        self.assertIn("id=999", logs.output[0])
        self.assertIn("A new workshop", logs.output[0])
        self.assertIn("Mystery campus", logs.output[0])

    def test_fallback_route_diagnostic_is_emitted_once_per_walk(self):
        page = {"Items": [event(41946, {"Name": "Online"})]}
        with patch.object(ucb_classes, "fetch_json", return_value=page):
            with self.assertLogs("ucb.classes.source", level="INFO") as logs:
                ucb_classes.fetch_ny()
                ucb_classes.fetch_la()
                self.assertEqual(len(ucb_classes.fetch_online()), 1)
        self.assertEqual(len(logs.output), 1)
        self.assertIn("routed from venue id=41946", logs.output[0])
        self.assertIn("A new workshop", logs.output[0])
        self.assertIn("Online", logs.output[0])
        self.assertIn("LOC_Online", logs.output[0])


if __name__ == "__main__":
    unittest.main()

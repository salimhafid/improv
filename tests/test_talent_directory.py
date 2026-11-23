"""Fallback to the public roster controls when the collection is unavailable."""
import json
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from sources import ucb_talent


def bootstrap(path):
    return f"""<link rel="canonical" href="https://ucbcomedy.com/talent/{path}/">
        <div class="ucb-team-grid" data-options='{{"id":"team_grid_live","isTemplate":true}}'></div>
        <div class="wpgb-facet" data-grid="team_grid_live" data-facet="20"></div>
        <div class="wpgb-facet" data-grid="team_grid_live" data-facet="21"></div>
        <div class="wpgb-facet" data-grid="team_grid_live" data-facet="22"></div>"""


def response(offset, *, location="ny-talent", rows=None, total=3, sort="title_asc"):
    rows = range(offset, min(offset + 2, total)) if rows is None else rows
    cards = ''.join(f"""<article class="ucb-team-card"><div class="wpgb-card-media-thumbnail">
        <a href="https://ucbcomedy.com/people/person-{i}/" aria-label="A &amp; B {i}">
        <img src="https://ucbcomedy.com/photo-{i}.jpg"></a></div></article>""" for i in rows)
    return {"posts": cards, "total": total, "facets": {
        "21": {"type": "talent_location_buttons", "slug": "filter_location_buttons",
               "selected": [location] if location else []},
        "22": {"type": "sort", "slug": "filter_sort", "selected": [sort]},
        "20": {"type": "load_more", "slug": "load_more_directory",
               "settings": {"offset": offset, "number": 2}},
    }}


class PublicDirectoryTests(unittest.TestCase):
    def test_uses_published_grid_settings_selection_and_alphabetical_pagination(self):
        for group, location, directory in (("ny", "ny-talent", "all-talent"), ("la", "la-talent", "all-talent"),
                                            ("dcm", "dcm", "all-talent"), ("teachers", "", "teachers")):
            calls = []
            def post(url, data, retries):
                self.assertEqual(retries, 1)
                args = parse_qs(urlsplit(url).query)
                self.assertEqual(args.get("_filter_location_buttons", []), [location] if location else [])
                self.assertEqual(args["_filter_sort"], ["title_asc"])
                self.assertEqual(args["wpgb-ajax"], ["refresh"])
                config = json.loads(data["wpgb"])
                self.assertEqual(config["id"], "team_grid_live")
                self.assertEqual(config["facets"], [20, 21, 22])
                self.assertEqual(config["permalink"], f"https://ucbcomedy.com/talent/{directory}/")
                offset = int(args.get("_load_more_directory", ["0"])[0])
                calls.append(offset)
                return response(offset, location=location)

            with self.subTest(group=group), patch.object(ucb_talent, "fetch_json", side_effect=RuntimeError("HTTP 202")), \
                    patch.object(ucb_talent, "fetch_html", return_value=bootstrap(directory)) as bootstrap_page, \
                    patch.object(ucb_talent, "post_json", side_effect=post):
                people = ucb_talent.fetch_group(group)
                expected_entry = f"https://ucbcomedy.com/talent/{directory}/"
                if location:
                    expected_entry += f"?_filter_location_buttons={location}"
                bootstrap_page.assert_called_once_with(expected_entry, retries=1)
                self.assertEqual(calls, [0, 2])
                self.assertEqual(people[-1], {"slug": "person-2", "name": "A & B 2",
                                              "url": "https://ucbcomedy.com/people/person-2/",
                                              "image": "https://ucbcomedy.com/photo-2.jpg", "dcm": group == "dcm"})

    def test_ignored_filter_repeated_page_changed_total_and_wrong_offset_fail(self):
        partials = [response(0, location=""), response(0, sort=""), response(2, rows=[0]),
                    response(2, rows=[]), response(2, total=4)]
        for last in partials:
            with self.subTest(last=last), patch.object(ucb_talent, "fetch_html", return_value=bootstrap("all-talent")), \
                    patch.object(ucb_talent, "post_json", side_effect=[response(0), last]):
                with self.assertRaises(RuntimeError):
                    ucb_talent._directory_group("ny")

    def test_declined_public_page_does_not_attempt_further_requests(self):
        with patch.object(ucb_talent, "fetch_json", side_effect=RuntimeError("REST 202")), \
                patch.object(ucb_talent, "fetch_html", side_effect=RuntimeError("directory 403")) as page, \
                patch.object(ucb_talent, "post_json") as grid:
            with self.assertRaisesRegex(RuntimeError, "directory 403.*REST 202"):
                ucb_talent.fetch_group("ny")
            page.assert_called_once_with("https://ucbcomedy.com/talent/all-talent/?_filter_location_buttons=ny-talent", retries=1)
            grid.assert_not_called()

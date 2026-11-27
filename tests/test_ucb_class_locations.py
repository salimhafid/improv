"""UCB's registration page feeds both the class browser and class alerts."""
from contextlib import ExitStack
from datetime import date
import unittest
from unittest.mock import patch

from sources import ucb_classes
import watcher


def section(*, title="Improv 101", course="improv-101/1001", city="New York",
            venue="Union Square", open_seats="0", categories="improv", frequency="weekly",
            group="Improv 101: Improv Basics", teacher="Jacklyn Uweh", dates="Nov 29 – Jan 31",
            pattern="Sundays 11am-2pm ET", standalone=False):
    where = venue + (f'<span class="ucb-cl-run-sub">{city}</span>' if city != "Online" else "")
    if standalone:
        table = f'<div class="ucb-cl-course-body"><table><caption>Class times for {title}</caption>'
        close = "</table></div>"
    else:
        table = f'<section class="ucb-cl-sub"><h3 class="ucb-cl-sub-title">{title}</h3><table>'
        close = "</table></section>"
    return f"""
    <article class="ucb-cl-course"><h2 class="ucb-cl-course-title">{group}</h2>
    {table}<tbody>
    <tr class="ucb-cl-run" data-cat="{categories}" data-freq="{frequency}" data-open="{open_seats}">
    <td data-label="Schedule"><span class="ucb-cl-run-value">{pattern}</span></td>
    <td data-label="Where"><span class="ucb-cl-run-value">{where}</span></td>
    <td data-label="Instructor"><span class="ucb-cl-avatar">AB</span>
    <span class="ucb-cl-run-value">{teacher}</span></td>
    <td data-label="Starts">{dates}</td><td data-label="Price">$525.00</td>
    <td data-label="Status"><a href="/course/{course}/">Register</a></td></tr>
    </tbody>{close}</article>"""


def page(*sections):
    return f'<p class="ucb-cl-count">Showing {len(sections)} classes</p>' + ''.join(sections)


class UcbCatalogTests(unittest.TestCase):
    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        self.fetch = stack.enter_context(patch.object(ucb_classes, 'fetch_html'))
        stack.enter_context(patch.object(ucb_classes, 'local_today', return_value=date(2026, 11, 22)))
        stack.enter_context(patch.object(ucb_classes, '_memo', None))

    def test_shared_catalog_routes_native_sections_and_preserves_known_ids(self):
        self.fetch.return_value = page(section(),
            section(city="Los Angeles", venue="Franklin Campus", course="new-improv/001", open_seats="1"),
            section(city="Online", venue="Online", course="online-lab/001", title="Performance Lab",
                    categories="improv-electives featured-programs", frequency="workshop",
                    group="Performance", teacher="Sam", pattern="Tuesdays 4pm-6pm PT", dates="Jan 5 – Jan 12"),
            section(city="Austin", venue="ColdTowne Campus", course="improv-101/1003"))
        (ny,) = ucb_classes.fetch_ny()
        (la,) = ucb_classes.fetch_la()
        (online,) = ucb_classes.fetch_online()
        self.assertEqual(ny['id'], "ucb_ny/42873")
        self.assertEqual(ny['url'], "https://ucbcomedy.com/course/improv-101/1001/")
        self.assertEqual((ny['title'], ny['instructor'], ny['schedule'], ny['start'], ny['price'],
                          ny['is_full'], ny['location'], ny['level']),
                         ("Improv 101", "Jacklyn Uweh", "Sundays 11am-2pm ET · Nov 29 – Jan 31",
                          "2026-11-29T11:00:00", "$525.00", True, "Union Square, New York",
                          "Improv 101: Improv Basics"))
        self.assertFalse(la['is_full'])
        self.assertEqual(online['location'], "Online")
        self.assertEqual(online['start'], "2027-01-05T19:00:00")
        scanned = watcher.scan_ucb()
        self.assertEqual(sum(map(len, scanned.values())), 3)
        self.assertEqual(scanned["ucb_ny"]["42873"]["categories"], ["improv_core"])
        # Existing numeric Arlo state must only notify for actual new sections.
        state = {"ucb_ny": {"ids": ["42873"]}, "ucb_online": {"ids": []}}
        alerts = watcher.diff_and_alert(scanned, state, per_category=True)
        self.assertEqual(len(alerts), 1)
        alert = alerts[0]
        self.assertEqual((alert['classIDs'], alert['url']), (online['id'], online['url']))
        self.assertEqual(alert['categories'], ["improv_electives", "featured_programs", "workshops"])
        self.assertEqual(alert['pushBody'], "Performance Lab\nSam\nPerformance workshop")
        self.assertEqual(watcher.diff_and_alert(scanned, state, per_category=True), [])
        self.fetch.assert_called_once()

    def test_group_fills_missing_category_and_in_person_clock_stays_venue_local(self):
        self.fetch.return_value = page(section(city="Los Angeles", venue="Silver Lake", title="Character 201",
            group="Character", categories="", frequency="intensive", pattern="Wednesdays 7pm-10pm ET"),
            section(course="online-commercial-auditioning/003", city="Online", venue="Online",
                    group="Acting", title="ONLINE Commercial Auditioning", categories=""))
        (la,) = ucb_classes.fetch_la()
        self.assertEqual(la["start"], "2026-11-29T19:00:00")
        self.assertEqual(la["schedule"], "Wednesdays 7pm-10pm · Nov 29 – Jan 31")
        scanned = watcher.scan_ucb()
        self.assertEqual(next(iter(scanned["ucb_la"].values()))["categories"], ["sketch_character", "intensives"])
        self.assertEqual(next(iter(scanned["ucb_online"].values()))["categories"], ["acting"])

    def test_only_new_uncategorized_noncore_sections_fetch_explicit_detail_subjects(self):
        def acting(slug, **kwargs):
            return section(course=slug, city="Online", venue="Online", title="Commercial Auditioning",
                           categories="", group="Acting", **kwargs)
        listing = page(acting("auditions/095"), acting("auditions/096"), acting("auditions/097"),
                       section(title="Sketch 201", course="writing/011", categories="", city="Online",
                               venue="Online", group="Sketch and Character", frequency="workshop"),
                       section(course="new-lab/003", categories="featured-programs", city="Online",
                               venue="Online", title="Featured Lab", group="Featured Programs"),
                       section(course="first-campus/001", categories="", title="LA Lab", city="Los Angeles"))
        tag_html = '<p class="ucb-class-band__tagline">Category: Acting / Featured Programs</p>'
        def fetch(url):
            if "training-center" in url:
                return listing
            if "/096/" in url:
                return tag_html
            if "/097/" in url:
                raise RuntimeError("site unavailable")
            self.fail("Unexpected section lookup " + url)
        self.fetch.side_effect = fetch
        state = {"ucb_online": {"ids": ["section-auditions-095"]}}
        scanned = watcher.scan_ucb(state)
        online = scanned["ucb_online"]
        self.assertEqual(online["section-auditions-096"]["categories"], ["acting", "featured_programs"])
        self.assertEqual(online["section-auditions-097"]["categories"], ["acting"])
        self.assertEqual(online["section-writing-011"]["categories"], ["sketch_core"])
        self.assertEqual(self.fetch.call_count, 3)
        alerts = watcher.diff_and_alert(scanned, state, per_category=True)
        self.assertTrue(any(a["classIDs"].endswith("096") and "featured_programs" in a["categories"] for a in alerts))
        watcher.scan_ucb(state)
        self.assertEqual(self.fetch.call_count, 3, "known sections keep the two-minute scan to the catalog")

    def test_large_drop_bounds_section_detail_lookups_and_keeps_the_remaining_alerts(self):
        listing = page(*(section(course=f"acting-lab/{i:03}", title="Lab", group="Acting", categories="")
                         for i in range(watcher._MAX_UCB_CATEGORY_LOOKUPS + 2)))
        self.fetch.side_effect = lambda url: listing if "training-center" in url else ""
        scanned = watcher.scan_ucb({"ucb_ny": {"ids": []}})
        self.assertEqual(len(scanned["ucb_ny"]), watcher._MAX_UCB_CATEGORY_LOOKUPS + 2)
        self.assertEqual(self.fetch.call_count, 1 + watcher._MAX_UCB_CATEGORY_LOOKUPS)
        self.assertTrue(all(item["categories"] == ["acting"] for item in scanned["ucb_ny"].values()))

    def test_one_publish_keeps_one_catalog_across_slow_enrichment(self):
        self.fetch.side_effect = [page(section()), page(section(title="Replacement"))]
        with patch.object(ucb_classes, "_MEMO_TTL", 0):
            with ucb_classes.feed_snapshot():
                first = ucb_classes.catalog()
                self.assertIs(ucb_classes.catalog(), first)
            with ucb_classes.feed_snapshot():
                self.assertNotEqual(ucb_classes.catalog(), first)
        self.assertEqual(self.fetch.call_count, 2)

    def test_same_section_number_on_two_courses_has_distinct_ids(self):
        self.fetch.return_value = page(section(course="course-one/001"), section(course="course-two/001"))
        rows = ucb_classes.fetch_ny()
        self.assertEqual(len({row["id"] for row in rows}), 2)

    def test_standalone_course_keeps_existing_sections_and_announces_once(self):
        seminar = section(course="sketch-seminar/1", title="Sketch Seminar", group="Sketch Seminar",
                          open_seats="1", categories="sketch-electives writing-programs workshop",
                          frequency="workshop", teacher="Haley Hepworth", standalone=True)
        self.fetch.return_value = page(section(), seminar)
        original, new = ucb_classes.fetch_ny()
        self.assertEqual(original["id"], "ucb_ny/42873")
        self.assertEqual((new["id"], new["title"], new["level"], new["instructor"], new["is_full"]),
                         ("ucb_ny/section-sketch-seminar-1", "Sketch Seminar", "Sketch Seminar", "Haley Hepworth", False))
        state = {"ucb_ny": {"ids": ["42873"]}}
        scanned = watcher.scan_ucb(state)
        alerts = watcher.diff_and_alert(scanned, state, per_category=True)
        self.assertEqual([a["classIDs"] for a in alerts], [new["id"]])
        self.assertEqual(watcher.diff_and_alert(scanned, state, per_category=True), [])

    def test_standalone_uses_its_course_heading_without_a_caption(self):
        item = section(title="Sketch Seminar", group="Sketch Seminar", standalone=True)
        self.fetch.return_value = page(item.replace("<caption>Class times for Sketch Seminar</caption>", ""))
        self.assertEqual(ucb_classes.fetch_ny()[0]["title"], "Sketch Seminar")

    def test_table_caption_names_the_course_under_a_broader_curriculum(self):
        item = section().replace('<h3 class="ucb-cl-sub-title">Improv 101</h3>', "")
        self.fetch.return_value = page(item.replace("<tbody>", "<caption>Class times for Improv 101</caption><tbody>"))
        self.assertEqual(ucb_classes.fetch_ny()[0]["title"], "Improv 101")

    def test_partial_or_malformed_page_fails_once_without_partial_results(self):
        fixture = section()
        for bad in [page(), page(fixture).replace("Showing 1", "Showing 2"), page(fixture, fixture),
                    page(fixture).replace('<h3 class="ucb-cl-sub-title">Improv 101</h3>', ''),
                    page(fixture).replace('/course/improv-101/1001/', '/course/improv-101/'),
                    page(fixture).replace('/course/improv-101/1001/', 'https://example.org/course/i/1/'),
                    page(fixture).replace('data-label="Where"', 'data-label="Elsewhere"'),
                    page(fixture).replace('data-open="0"', 'data-open=""')]:
            with self.subTest(bad=bad), patch.object(ucb_classes, "_memo", None):
                self.fetch.reset_mock()
                self.fetch.return_value = bad
                with self.assertRaises(ValueError):
                    ucb_classes.fetch_ny()
                with self.assertRaises(RuntimeError):
                    watcher.scan_ucb()
                self.fetch.assert_called_once()

    def test_year_rollover_keeps_recent_december_starts_in_december(self):
        start = ucb_classes._start
        jan2 = date(2027, 1, 2)
        self.assertEqual(start("Dec 30 – Jan 12", "4pm-6pm", "New York", jan2), "2026-12-30T16:00:00")
        self.assertEqual(start("Jan 8", "Time TBD", "New York", jan2), "2027-01-08")
        self.assertEqual(start("March 12, 2028", "", "New York", jan2), "2028-03-12")
        self.assertIsNone(start("TBD", "", "New York", jan2))

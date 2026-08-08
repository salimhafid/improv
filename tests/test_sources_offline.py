"""Offline adapter tests: synthetic fixtures + patched fetchers. No network.

Each adapter's parsing/windowing logic runs against small hand-built HTML/JSON
that mirrors the live markup documented in CONTEXT.md, so a refactor that
breaks a parser fails here instead of silently shipping an empty source.
"""
from __future__ import annotations

import unittest
from datetime import date, timedelta
from unittest.mock import patch

from sources import crowdwork, magnet, playground, second_city, ucb, wgis


def _iso(day: date, hh: int = 20, offset: str = "-05:00") -> str:
    return f"{day.isoformat()}T{hh:02d}:00:00.000{offset}"


# ---- UCB (WP Grid Builder pagination) --------------------------------------

def _ucb_card(title: str, day: str, post_id: int) -> str:
    return f"""
    <article class="wpgb-card wpgb-post-{post_id}">
      <div class="ucb-event-post-title"><a href="https://ucbcomedy.com/show/{title.lower().replace(' ', '-')}-{post_id}/">{title}</a></div>
      <div class="event-post-date">Friday, {day} @ 7:00 PM</div>
      <div class="ucb-event-post-location"><span class="wpgb-block-term">UCB Theatre</span></div>
      <div class="ucb-event-post-comedy-types"><span class="wpgb-block-term">Improv</span></div>
      <img data-src="https://u.test/img-500x250.jpg"/>
      <div class="ucb-event-post-excerpt">A show.</div>
    </article>"""


def _ucb_page(cards: list[str]) -> str:
    return f"<html><body>{''.join(cards)}</body></html>"


class UcbPaginationTests(unittest.TestCase):
    def test_walks_pages_until_repeat(self):
        # Termination is content-based (a page contributing nothing new), NOT a
        # page-size heuristic — a smaller grid page must not truncate the walk.
        page1 = _ucb_page([_ucb_card(f"Show {i}", "June 19, 2026", i) for i in range(3)])
        pages = {
            "https://ucbcomedy.com/shows/new-york/": page1,
            "https://ucbcomedy.com/shows/new-york/?_page=2":
                _ucb_page([_ucb_card("Tail Show", "June 26, 2026", 999)]),
            "https://ucbcomedy.com/shows/new-york/?_page=3": page1,  # out-of-range repeat
        }
        calls = []
        with patch.object(ucb, "fetch_html", side_effect=lambda u: calls.append(u) or pages[u]):
            shows = ucb.fetch("ny")
        self.assertEqual(len(shows), 4)
        self.assertEqual(shows[-1]["title"], "Tail Show")
        self.assertEqual(len(calls), 3)  # stops on the repeat page

    def test_repeated_page_ends_walk(self):
        # Out-of-range ?_page=N re-serves page 1: the dedupe guard must stop.
        full = _ucb_page([_ucb_card(f"Show {i}", "June 19, 2026", i) for i in range(3)])
        calls = []
        with patch.object(ucb, "fetch_html", side_effect=lambda u: calls.append(u) or full):
            shows = ucb.fetch("ny")
        self.assertEqual(len(shows), 3)
        self.assertEqual(len(calls), 2)  # page 1 + one repeat, then stop

    def test_empty_page_one_raises(self):
        # Zero cards on page 1 means the markup moved — must raise so the
        # aggregator carries last-good data instead of publishing a wipe.
        with patch.object(ucb, "fetch_html", return_value="<html><body>redesign</body></html>"):
            with self.assertRaises(RuntimeError):
                ucb.fetch("ny")

    def test_card_fields(self):
        page = _ucb_page([_ucb_card("Harold Night", "June 19, 2026", 7)])
        shows = ucb._parse_cards(page, "ucb_ny", "UCB", "New York")
        (s,) = shows
        self.assertEqual(s["title"], "Harold Night")
        self.assertEqual(s["start"], "2026-06-19T19:00:00")
        self.assertTrue(s["has_time"])
        self.assertEqual(s["venue"], "UCB Theatre")
        # -WxH thumbnail suffix stripped to the full-size original
        self.assertEqual(s["image"], "https://u.test/img.jpg")
        self.assertEqual(s["post_id"], 7)


class UcbCastTests(unittest.TestCase):
    def test_multiline_cast(self):
        text = "About\nFeaturing:\nAva One\nBo Two\n—\nTickets $10"
        self.assertEqual(ucb._extract_cast(text), "Ava One, Bo Two")

    def test_stops_at_ticket_words(self):
        text = "Featuring:\nAva One\nGet tickets here"
        self.assertEqual(ucb._extract_cast(text), "Ava One")

    def test_no_label(self):
        self.assertEqual(ucb._extract_cast("just a description"), "")


# ---- Crowdwork (per-date expansion) ----------------------------------------

def _cw_show(name: str, dates: list[str], *, status="active", spots=None, venue="Main"):
    return {
        "name": name, "status": status, "url": f"https://crowdwork.com/e/{name.lower()}",
        "venue": venue, "next_date": dates[0] if dates else None, "dates": dates,
        "img": {"large": "https://c.test/i.jpg"},
        "tags": {"public": ["Improv"]},
        "cost": {"formatted": "$5"},
        "description": {"body": "<p>Fun</p>"}, "description_short": "Fun",
        "badges": {"spots": spots} if spots else {},
    }


class CrowdworkShowTests(unittest.TestCase):
    def setUp(self):
        crowdwork._memo.clear()
        self.today = date.today()

    def _fetch(self, payload):
        return patch.object(crowdwork, "fetch_json", return_value={"data": payload})

    def test_expands_every_future_date(self):
        days = [self.today + timedelta(days=7 * i) for i in range(4)]
        with self._fetch([_cw_show("Weekly", [_iso(d) for d in days])]):
            shows = crowdwork.fetch_shows("x", "src", "Org", "Chicago")
        self.assertEqual(len(shows), 4)
        self.assertEqual(len({s["slug"] for s in shows}), 4)  # unique per occurrence

    def test_past_and_beyond_horizon_dropped(self):
        days = [self.today - timedelta(days=1), self.today,
                self.today + timedelta(days=crowdwork._SHOW_HORIZON_DAYS + 1)]
        with self._fetch([_cw_show("Edges", [_iso(d) for d in days])]):
            shows = crowdwork.fetch_shows("x", "src", "Org", "Chicago")
        self.assertEqual([s["start"][:10] for s in shows], [self.today.isoformat()])

    def test_next_date_unioned_when_no_dates_array(self):
        d = self.today + timedelta(days=3)
        show = _cw_show("Single", [_iso(d)])
        show["dates"] = []
        with self._fetch([show]):
            shows = crowdwork.fetch_shows("x", "src", "Org", "Chicago")
        self.assertEqual(len(shows), 1)

    def test_inactive_dropped(self):
        d = self.today + timedelta(days=3)
        with self._fetch([_cw_show("Gone", [_iso(d)], status="archived")]):
            self.assertEqual(crowdwork.fetch_shows("x", "src", "Org", "Chicago"), [])

    def test_tz_split_keeps_only_matching_city(self):
        d = self.today + timedelta(days=3)
        ny = _cw_show("NY Show", [_iso(d, offset="-04:00")])
        la = _cw_show("LA Show", [_iso(d, offset="-07:00")])
        with self._fetch([ny, la]):
            got = crowdwork.fetch_shows("wgis", "wgis_la", "WGIS", "Los Angeles", city_from_tz=True)
        self.assertEqual([s["title"] for s in got], ["LA Show"])

    def test_sold_out_detection(self):
        self.assertTrue(crowdwork._is_full({"badges": {"spots": "Sold out"}}))
        self.assertTrue(crowdwork._is_full({"badges": {"spots": "Join the wait list"}}))
        self.assertFalse(crowdwork._is_full({"badges": {"spots": "Only 2 spots left"}}))
        self.assertFalse(crowdwork._is_full({}))


class CrowdworkClassTests(unittest.TestCase):
    def setUp(self):
        crowdwork._memo.clear()

    def test_past_dated_run_dropped_undated_kept(self):
        past = _cw_show("Ended", [_iso(date.today() - timedelta(days=30))])
        past["next_date"] = None
        undated = _cw_show("Drop-in", [])
        undated["next_date"] = None
        with patch.object(crowdwork, "fetch_json", return_value={"data": [past, undated]}):
            classes = crowdwork.fetch_classes("x", "src", "Org", "Chicago")
        self.assertEqual([c["title"] for c in classes], ["Drop-in"])
        self.assertIsNone(classes[0]["start"])


# ---- Magnet (calendar + class pages) ---------------------------------------

_MAGNET_MONTH = """
<table><tr>
  <td><strong class="date">19</strong>
    <div class="an-event"><a href="https://magnettheater.com/show/123/">
      <p class="summary">Megawatt</p></a><span class="time">8:00pm - $10</span></div>
  </td>
  <td><strong class="date"></strong></td>
</tr></table>"""


def _magnet_class_card(cid: int, ctype: str, starts: str, ends: str, status: str = "Open") -> str:
    return f"""
    <div class="class-holder">
      <div class="instructor"><a>Jane Doe</a></div>
      <div class="details">
        <strong><a href="{cid}">{ctype}</a></strong><br>
        {ctype}
        Mondays 7-10pm
        Starts:
        {starts}
        Ends:
        {ends}
        {status}
      </div>
    </div>"""


class MagnetTests(unittest.TestCase):
    def test_month_parse(self):
        shows = magnet._parse_month(_MAGNET_MONTH, 2026, 6)
        (s,) = shows
        self.assertEqual(s["title"], "Megawatt")
        self.assertEqual(s["start"], "2026-06-19T20:00:00")

    def test_classes_merge_index_and_discipline_pages(self):
        today = date(2026, 7, 22)
        index = f"""<html><nav>
          <a href="https://magnettheater.com/class/improv-level-one/">L1</a>
          <a href="https://magnettheater.com/class/all-classes-in-session/">All</a>
        </nav>{_magnet_class_card(11, "Improv Level Two", "July 1st", "September 1st")}</html>"""
        discipline = f"""<html>
          {_magnet_class_card(11, "Improv Level Two", "July 1st", "September 1st")}
          {_magnet_class_card(22, "Improv Level One", "September 19th", "November 7th")}
        </html>"""
        pages = {magnet.CLASS_INDEX: index,
                 "https://magnettheater.com/class/improv-level-one/": discipline}
        with patch.object(magnet, "fetch_html", side_effect=lambda u: pages[u]):
            classes = magnet.fetch_classes(today)
        self.assertEqual(len(classes), 2)  # cid 11 deduped across pages
        by_id = {c["id"]: c for c in classes}
        self.assertIsNone(by_id["magnet/11"]["start"])          # in-session: undated
        self.assertEqual(by_id["magnet/22"]["start"], "2026-09-19")  # upcoming: dated

    def test_ended_sections_dropped(self):
        today = date(2026, 7, 22)
        index = f"<html>{_magnet_class_card(5, 'Sketch Writing One', 'May 1st', 'June 30th')}</html>"
        with patch.object(magnet, "fetch_html", return_value=index):
            self.assertEqual(magnet.fetch_classes(today), [])

    def test_infer_date_year_boundary(self):
        # A January date seen in December belongs to next year, not 11 months ago.
        self.assertEqual(magnet._infer_date("January 10th", date(2026, 12, 20)),
                         date(2027, 1, 10))
        self.assertEqual(magnet._infer_date("December 28th", date(2027, 1, 3)),
                         date(2026, 12, 28))


# ---- Second City (classes data route + show helpers) -----------------------

def _sc_section(aid: int, status="Open", begin="2026-08-29", open_seats="8"):
    return {
        "activity_name": "Improv 1", "activity_id": str(aid),
        "activity_status": status, "default_beginning_date": begin,
        "default_ending_date": "2026-10-17",
        "default_pattern_dates": "Saturday,12:00 PM,3h",
        "NUMBEROFSESSIONS": "7", "NUMBER_OPEN": open_seats,
        "activity_valid_from": f"{begin}T12:00:00r",
    }


def _sc_payload(sections):
    import json as _json
    return {"pageProps": {"dehydratedState": {"queries": [{"state": {"data": {"classes": {"nodes": [{
        "title": "Improv 1", "uri": "/classes/chicago/improv/improv-1-chi",
        "activenetData": {"activenetData": _json.dumps(sections)},
        "classesCategories": {"nodes": [{"name": "Improv"}]},
        "classes": {"flexibleLayout": [
            {"description": "<p>Yes, and.</p>", "price": "395",
             "imageDesktop": {"mediaItemUrl": "https://sc.test/i.jpg"}}]},
    }]}}}}]}}}


class SecondCityClassTests(unittest.TestCase):
    def _run(self, sections, today=date(2026, 7, 22)):
        with patch.object(second_city, "fetch_html", return_value='x "buildId":"BID" x'), \
             patch.object(second_city, "fetch_json", return_value=_sc_payload(sections)):
            return second_city.fetch_classes(today)

    def test_open_future_sections_emitted(self):
        classes = self._run([_sc_section(1), _sc_section(2, begin="2026-09-01")])
        self.assertEqual(len(classes), 2)
        c = classes[0]
        self.assertEqual(c["start"], "2026-08-29T12:00:00")   # 'r' suffix stripped
        self.assertEqual(c["price"], "$395")
        self.assertEqual(c["level"], "Improv")
        self.assertEqual(c["schedule"], "Saturdays 12:00 PM · Aug 29 – Oct 17 · 7 sessions")
        self.assertFalse(c["is_full"])

    def test_closed_and_past_sections_dropped(self):
        classes = self._run([
            _sc_section(1, status="Closed"),
            _sc_section(2, begin="2026-01-01"),
            _sc_section(3),
        ])
        self.assertEqual([c["id"] for c in classes], ["second_city/3"])

    def test_zero_open_seats_marks_full(self):
        (c,) = self._run([_sc_section(1, open_seats="0")])
        self.assertTrue(c["is_full"])

    def test_missing_build_id_raises(self):
        with patch.object(second_city, "fetch_html", return_value="<html>no next data</html>"):
            with self.assertRaises(RuntimeError):
                second_city.fetch_classes(date(2026, 7, 22))


class SecondCityShowHelperTests(unittest.TestCase):
    def test_stage_heuristic(self):
        self.assertEqual(second_city._stage("x-mainstage-y", ""), "Mainstage")
        self.assertEqual(second_city._stage("show-etc-revue", ""), "e.t.c. Theater")
        self.assertEqual(second_city._stage("skybox-jam", ""), "Donny's Skybox")
        self.assertEqual(second_city._stage("pandemonium", "Pandemonium"), "")

    def test_decode_blob_tolerates_padding(self):
        import base64, json as _json
        blob = base64.b64encode(_json.dumps({"a": 1}).encode()).decode().rstrip("=")
        self.assertEqual(second_city._decode_blob(blob), {"a": 1})
        self.assertIsNone(second_city._decode_blob("!!!not base64!!!"))


# ---- WGIS classes ----------------------------------------------------------

_WGIS_PAGE = """
<html><h4>NYC Workshops</h4>
<div class="row mb-1">
  <div class="col-3"><a href="/workshop/view/42">Drop-In</a> SOLD OUT</div>
  <div class="col-3">Jane Host</div>
  <div class="col-3">Thu Jul 23 7pm (2 hrs)</div>
  <div class="col-3">$20</div>
</div></html>"""


class WgisYearBoundaryTests(unittest.TestCase):
    def test_january_class_seen_in_december_lands_next_year(self):
        start = wgis._parse_when_start("Sat Jan 9 7pm (2 hrs)", today=date(2026, 12, 20))
        self.assertEqual(start, "2027-01-09T19:00:00")

    def test_recent_past_class_keeps_its_year(self):
        # "Currently running" listings sit a few weeks back — no rollover.
        start = wgis._parse_when_start("Thu Jul 9 7pm (2 hrs)", today=date(2026, 7, 22))
        self.assertEqual(start, "2026-07-09T19:00:00")


# ---- Playground (ICS parsing) ----------------------------------------------

class PlaygroundIcsTests(unittest.TestCase):
    def test_multivalue_exdate_all_parsed(self):
        ics = "\n".join([
            "BEGIN:VEVENT",
            "SUMMARY:Weekly Jam",
            "DTSTART:20260701T190000",
            "RRULE:FREQ=WEEKLY",
            "EXDATE:20260708T190000,20260715T190000",
            "END:VEVENT",
        ])
        (ev,) = playground._events(ics)
        self.assertEqual(len(ev["exdates"]), 2)

    def test_date_only_until_expands(self):
        # All-day recurring events carry a date-only UNTIL, which dateutil
        # rejects against an aware dtstart unless normalized.
        ics = "\n".join([
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "SUMMARY:Free Night",
            "DTSTART;VALUE=DATE:20260724",
            "RRULE:FREQ=WEEKLY;UNTIL=20260807",
            "END:VEVENT",
            "END:VCALENDAR",
        ])
        with patch.object(playground, "fetch_html", return_value=ics):
            shows = playground.fetch(date(2026, 7, 22))
        self.assertEqual([s["start"] for s in shows],
                         ["2026-07-24", "2026-07-31", "2026-08-07"])


class WgisClassTests(unittest.TestCase):
    def test_parse_row(self):
        classes = wgis._parse_classes(_WGIS_PAGE, "wgis_ny", "New York")
        (c,) = classes
        self.assertEqual(c["id"], "wgis_ny/42")
        self.assertEqual(c["title"], "Drop-In")
        self.assertEqual(c["instructor"], "Jane Host")
        self.assertEqual(c["price"], "$20")
        self.assertTrue(c["is_full"])
        self.assertEqual(c["level"], "NYC Workshops")
        self.assertTrue(c["start"].startswith(f"{date.today().year}-07-23"))


if __name__ == "__main__":
    unittest.main()

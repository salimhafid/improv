"""Offline adapter tests: synthetic fixtures + patched fetchers. No network.

Each adapter's parsing/windowing logic runs against small hand-built HTML/JSON
that mirrors the live markup documented in CONTEXT.md, so a refactor that
breaks a parser fails here instead of silently shipping an empty source.
"""
from __future__ import annotations

import unittest
from datetime import date, timedelta
from unittest.mock import patch

from sources import crowdwork, magnet, playground, second_city, ucb, ucb_classes, ucb_talent, wgis


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
        self.assertFalse(s["is_free"])

    def test_is_free_is_a_whole_word(self):
        page = _ucb_page([_ucb_card("Freestyle Love Supreme", "June 19, 2026", 1),
                          _ucb_card("*FREE* ASSSSCAT NY", "June 19, 2026", 2)])
        free = {s["title"]: s["is_free"] for s in ucb._parse_cards(page, "ucb_ny", "UCB", "New York")}
        self.assertEqual(free, {"Freestyle Love Supreme": False, "*FREE* ASSSSCAT NY": True})


class UcbCastTests(unittest.TestCase):
    def test_multiline_cast(self):
        text = "About\nFeaturing:\nAva One\nBo Two\n—\nTickets $10"
        self.assertEqual(ucb._extract_cast(text), "Ava One, Bo Two")

    def test_stops_at_ticket_words(self):
        text = "Featuring:\nAva One\nGet tickets here"
        self.assertEqual(ucb._extract_cast(text), "Ava One")

    def test_no_label(self):
        self.assertEqual(ucb._extract_cast("just a description"), "")

    def test_long_comma_list_on_label_line_is_kept(self):
        names = ", ".join(f"Performer Number {i}" for i in range(8))   # > 80 chars
        self.assertEqual(ucb._extract_cast(f"Featuring: {names}\n—\nTickets"), names)
        # …but a long sentence that merely contains commas is not a lineup.
        blurb = "the funniest people in town, plus surprise guests and more improvisers than you can count"
        self.assertEqual(ucb._extract_cast(f"Featuring: {blurb}\nTickets $10"), "")

    def test_label_must_start_a_word(self):
        # "Podcast:" / "Broadcast:" contain "cast:" but are not a lineup.
        self.assertEqual(ucb._extract_cast("Our Podcast: The Weekly\nJohn Doe\nJane Roe"), "")
        self.assertEqual(ucb._extract_cast("Live Broadcast: tonight\nJohn Doe"), "")
        self.assertEqual(ucb._extract_cast("Cast: Ava One, Bo Two"), "Ava One, Bo Two")

    def test_caps_cut_at_a_word_boundary_with_ellipsis(self):
        text = " ".join(["word"] * 200)
        cut = ucb._truncate(text, 50)
        self.assertLessEqual(len(cut), 50)
        self.assertTrue(cut.endswith("\u2026"))
        self.assertFalse(cut[:-1].endswith("wor"))   # no mid-word cut
        self.assertEqual(ucb._truncate("short", 50), "short")


def _ucb_show_page(*, with_main: bool = True, description: str = "About the show.") -> str:
    people = ('<a href="https://ucbcomedy.com/people/ava-one/">Ava One</a>'
              '<a href="https://ucbcomedy.com/people/bo-two/">Bo Two</a>')
    body = (f'<div id="main"><div class="ucb-event-description"><p>{description}</p></div>{people}</div>'
            if with_main else f'<div class="ucb-event-description"><p>{description}</p></div>{people}')
    return (f'<html><head><meta property="og:image" content="https://u.test/hero.jpg"></head>'
            f'<body><nav><a href="https://ucbcomedy.com/people/nav-team/">Nav Team</a></nav>{body}</body></html>')


class UcbDetailTests(unittest.TestCase):
    def test_linked_cast_scans_only_main(self):
        from bs4 import BeautifulSoup
        members = ucb._linked_cast(BeautifulSoup(_ucb_show_page(), "lxml"))
        self.assertEqual([m["slug"] for m in members], ["ava-one", "bo-two"])   # nav link excluded

    def test_missing_main_yields_no_cast_and_no_cache(self):
        from bs4 import BeautifulSoup
        # No #main: never fall back to the whole page (the nav's team links would
        # become every show's cast), and don't cache the result.
        self.assertEqual(ucb._linked_cast(BeautifulSoup(_ucb_show_page(with_main=False), "lxml")), [])
        with patch.object(ucb, "fetch_html", return_value=_ucb_show_page(with_main=False)):
            self.assertIsNone(ucb.detail("https://ucbcomedy.com/show/x/"))

    def test_detail_fields_and_description_cap(self):
        long_desc = " ".join(["blurb"] * 600)   # > 2000 chars
        with patch.object(ucb, "fetch_html", return_value=_ucb_show_page(description=long_desc)):
            description, cast, image, members = ucb.detail("https://ucbcomedy.com/show/x/")
        self.assertEqual(cast, "Ava One, Bo Two")
        self.assertEqual(image, "https://u.test/hero.jpg")
        self.assertEqual(len(members), 2)
        self.assertLessEqual(len(description), 2000)
        self.assertTrue(description.endswith("blurb\u2026"))


# ---- UCB classes (Arlo) ------------------------------------------------------

def _arlo_event(eid: int, summary: str, tag: str = "LOC_NY") -> dict:
    return {"EventID": eid, "Name": f"Improv 101: Section {eid}", "StartDateTime": "2026-10-01T19:00:00-04:00",
            "Summary": summary, "Tags": [tag], "Categories": [{"Name": "1. Improv"}],
            "Presenters": [{"Name": "Jane Doe"}], "AdvertisedOffers": []}


class UcbClassesTests(unittest.TestCase):
    def setUp(self):
        ucb_classes._memo = None
        self.addCleanup(setattr, ucb_classes, "_memo", None)

    def test_category_summary_is_not_a_description(self):
        page = {"Items": [_arlo_event(1, "Category: Improv &amp; Musical Improv"),
                          _arlo_event(2, "<p>Learn the Harold.</p>")]}
        with patch.object(ucb_classes, "fetch_json", return_value=page) as fj:
            by_id = {c["id"]: c for c in ucb_classes.fetch_ny()}
        self.assertEqual(by_id["ucb_ny/1"]["description"], "")
        self.assertEqual(by_id["ucb_ny/2"]["description"], "Learn the Harold.")
        self.assertEqual(by_id["ucb_ny/1"]["level"], "Improv")
        url = fj.call_args[0][0]
        self.assertNotIn("Location", url)   # never read; dropped from fields/expand
        self.assertNotIn("ViewUri", url)

    def test_failed_walk_is_memoised_within_a_run(self):
        # A mid-walk failure must not be re-walked by the LA and Online passes.
        with patch.object(ucb_classes, "fetch_json", side_effect=RuntimeError("arlo down")) as fj:
            for fetch in (ucb_classes.fetch_ny, ucb_classes.fetch_la, ucb_classes.fetch_online):
                with self.assertRaises(RuntimeError):
                    fetch()
        self.assertEqual(fj.call_count, 1)


# ---- UCB talent (DCM grid + dt_team pages) ----------------------------------

def _dcm_posts(offset: int, n: int, total: int, names=None) -> dict:
    names = names or [f"Person {offset + i}" for i in range(n)]
    posts = "".join(
        f'<a href="https://ucbcomedy.com/people/p-{offset + i}/" aria-label="{name}">'
        f'<img class="x" src="https://u.test/{offset + i}.jpg"></a>'
        for i, name in enumerate(names))
    return {"posts": posts, "total": total}


class UcbTalentTests(unittest.TestCase):
    def test_dcm_names_are_html_unescaped(self):
        payload = _dcm_posts(0, 2, 2, ["Brady O&#8217;Callahan", "Ethan &amp; Gigi"])
        with patch.object(ucb_talent, "post_json", return_value=payload):
            people, total = ucb_talent._dcm_batch(0)
        self.assertEqual([p["name"] for p in people], ["Brady O\u2019Callahan", "Ethan & Gigi"])
        self.assertEqual(total, 2)

    def test_one_failed_batch_is_not_fatal(self):
        # 60 people at 12 per batch: offset 24 fails, 48/60 = 80 % still passes.
        def fake_post(url, data):
            offset = int(url.rsplit("=", 1)[1])
            if offset == 24:
                raise RuntimeError("status=202 challenged=True")
            return _dcm_posts(offset, 12, 60)
        with patch.object(ucb_talent, "post_json", side_effect=fake_post):
            with self.assertLogs("ucb.talent", level="WARNING"):
                roster = ucb_talent.fetch_dcm_roster()
        self.assertEqual(len(roster), 48)

    def test_too_many_failed_batches_raise(self):
        def fake_post(url, data):
            offset = int(url.rsplit("=", 1)[1])
            if offset:
                raise RuntimeError("status=202 challenged=True")
            return _dcm_posts(0, 12, 60)
        with patch.object(ucb_talent, "post_json", side_effect=fake_post):
            with self.assertLogs("ucb.talent", level="WARNING"):
                with self.assertRaises(RuntimeError):
                    ucb_talent.fetch_dcm_roster()

    def test_page_names_are_unescaped(self):
        html = ('<div class="wf-cell" data-name="Ethan &amp; Gigi"><div class="team-container dt_team_category-dcm">'
                '<a href="https://ucbcomedy.com/people/ethan-gigi/"><img data-src="https://u.test/e.jpg"></a>'
                '</div></div>')
        with patch.object(ucb_talent, "fetch_html", return_value=html):
            (p,) = ucb_talent.fetch_page("https://ucbcomedy.com/talent/new-york/")
        self.assertEqual(p["name"], "Ethan & Gigi")
        self.assertTrue(p["dcm"])


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
        # The adapter cuts on Chicago-local today, not the machine's date:
        # the two differ on a UTC runner in the US evening.
        self.today = crowdwork.local_today("Chicago")

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

    def test_tz_split_prefers_the_timezone_field(self):
        # -05:00 is EST *and* CDT; the API's zone name settles it.
        d = self.today + timedelta(days=3)
        chi = _cw_show("Chicago Show", [_iso(d, offset="-05:00")])
        chi["timezone"] = "Central Time (US & Canada)"
        ny = _cw_show("NY Show", [_iso(d, offset="-05:00")])
        ny["timezone"] = "Eastern Time (US & Canada)"
        bare = _cw_show("Bare Show", [_iso(d, offset="-05:00")])   # no field → offset
        with self._fetch([chi, ny, bare]):
            got = crowdwork.fetch_shows("wgis", "wgis_ny", "WGIS", "New York", city_from_tz=True)
        self.assertEqual([s["title"] for s in got], ["NY Show", "Bare Show"])

    def test_sold_out_detection(self):
        self.assertTrue(crowdwork._is_full({"badges": {"spots": "Sold out"}}))
        self.assertTrue(crowdwork._is_full({"badges": {"spots": "Join the wait list"}}))
        self.assertTrue(crowdwork._is_full({"badges": {"spots": "Class is full"}}))
        self.assertFalse(crowdwork._is_full({"badges": {"spots": "Fully refundable"}}))
        self.assertFalse(crowdwork._is_full({"badges": {"spots": "Only 2 spots left"}}))
        self.assertFalse(crowdwork._is_full({}))

    def test_only_genre_tags_become_comedy_types(self):
        d = self.today + timedelta(days=3)
        show = _cw_show("Tagged", [_iso(d)])
        show["tags"] = {"public": ["Select Featured Shows", "Improv", "All Featured Shows",
                                   "front", "Stand-Up", "iO Classics"]}
        with self._fetch([show]):
            (s,) = crowdwork.fetch_shows("x", "src", "Org", "Chicago")
        self.assertEqual(s["comedy_types"], ["Improv", "Stand-Up"])

    def test_odd_field_types_do_not_crash_the_source(self):
        d = self.today + timedelta(days=3)
        odd = _cw_show("Odd", [_iso(d)])
        odd.update({"cost": "Free", "tags": ["Improv"], "img": "https://c.test/i.jpg", "url": 123, "id": 77})
        with self._fetch([odd, _cw_show("Fine", [_iso(d)])]):
            shows = crowdwork.fetch_shows("x", "src", "Org", "Chicago")
        self.assertEqual([s["title"] for s in shows], ["Odd", "Fine"])
        odd_show = shows[0]
        self.assertEqual(odd_show["url"], "")
        self.assertTrue(odd_show["slug"].startswith("77/"))   # numeric id, not ""
        self.assertIsNone(odd_show["image"])
        self.assertEqual(odd_show["comedy_types"], [])

    def test_occurrences_deduped_on_wall_clock(self):
        d = self.today + timedelta(days=3)
        show = _cw_show("Twice", [_iso(d)])
        show["next_date"] = _iso(d).replace(".000", "")   # same instant, different formatting
        with self._fetch([show]):
            shows = crowdwork.fetch_shows("x", "src", "Org", "Chicago")
        self.assertEqual(len(shows), 1)

    def test_malformed_well_shaped_date_skipped(self):
        d = self.today + timedelta(days=3)
        show = _cw_show("Bad Date", ["2026-13-45T99:00:00.000-05:00", _iso(d)])
        with self._fetch([show]):
            shows = crowdwork.fetch_shows("x", "src", "Org", "Chicago")
        self.assertEqual([s["start"][:10] for s in shows], [d.isoformat()])


class CrowdworkClassTests(unittest.TestCase):
    def setUp(self):
        crowdwork._memo.clear()
        self.today = crowdwork.local_today("Chicago")

    def test_past_dated_run_dropped_undated_kept(self):
        past = _cw_show("Ended", [_iso(self.today - timedelta(days=30))])
        past["next_date"] = None
        undated = _cw_show("Drop-in", [])
        undated["next_date"] = None
        with patch.object(crowdwork, "fetch_json", return_value={"data": [past, undated]}):
            classes = crowdwork.fetch_classes("x", "src", "Org", "Chicago")
        self.assertEqual([c["title"] for c in classes], ["Drop-in"])
        self.assertIsNone(classes[0]["start"])

    def test_past_next_date_does_not_shadow_future_dates(self):
        future = self.today + timedelta(days=8)
        running = _cw_show("Running", [_iso(self.today - timedelta(days=20)), _iso(future)])
        running["next_date"] = _iso(self.today - timedelta(days=20))
        stale = _cw_show("Stale", [])
        stale["next_date"] = _iso(self.today - timedelta(days=20))   # past, nothing upcoming
        with patch.object(crowdwork, "fetch_json", return_value={"data": [running, stale]}):
            classes = crowdwork.fetch_classes("x", "src", "Org", "Chicago")
        (c,) = classes
        self.assertEqual(c["title"], "Running")
        self.assertEqual(c["start"][:10], future.isoformat())
        self.assertTrue(c["schedule"].startswith(future.strftime("%A")))

    def test_malformed_class_date_is_not_published(self):
        bad = _cw_show("Bad", [])
        bad["next_date"] = "2026-13-45T99:00:00.000-05:00"
        with patch.object(crowdwork, "fetch_json", return_value={"data": [bad]}):
            (c,) = crowdwork.fetch_classes("x", "src", "Org", "Chicago")
        self.assertIsNone(c["start"])
        self.assertEqual(c["schedule"], "")

    def test_missing_url_falls_back_to_numeric_id(self):
        item = _cw_show("No URL", [_iso(self.today + timedelta(days=2))])
        item.update({"url": None, "id": 4242})
        with patch.object(crowdwork, "fetch_json", return_value={"data": [item]}):
            (c,) = crowdwork.fetch_classes("x", "src", "Org", "Chicago")
        self.assertEqual(c["id"], "src/4242")
        self.assertEqual(c["url"], "")


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
    # Mirrors the live div.details: the type link, then the schedule line,
    # then Starts:/Ends: pairs and the status (the type is NOT repeated as text).
    return f"""
    <div class="class-holder">
      <div class="instructor"><a>Jane Doe</a></div>
      <div class="details">
        <strong><a href="{cid}">{ctype}</a></strong><br>
        Mondays 7pm - 10pm (in-person)<br>
        Starts:<br>
        {starts}<br>
        Ends:<br>
        {ends}<br>
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
        self.assertEqual(by_id["magnet/22"]["schedule"],
                         "Mondays 7pm - 10pm (in-person) \u00b7 September 19th \u2013 November 7th")
        self.assertEqual(by_id["magnet/22"]["instructor"], "Jane Doe")
        self.assertFalse(by_id["magnet/22"]["is_full"])

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


_WGIS_RUNNING_PAGE = """
<html><h4><a href="#currentlyrunning">Currently Running</a></h4>
<div class="row mb-1">
  <div class="col-3"><a href="/workshop/view/1775">Level 3</a> WAITLIST</div>
  <div class="col-3">Jane Host</div>
  <div class="col-3">Tue Jul 14 7pm (LA) 8 classes</div>
  <div class="col-3">$400</div>
</div></html>"""


class WgisYearBoundaryTests(unittest.TestCase):
    def test_january_class_seen_in_december_lands_next_year(self):
        start = wgis._parse_when_start("Sat Jan 9 7pm (2 hrs)", today=date(2026, 12, 20))
        self.assertEqual(start, "2027-01-09T19:00:00")

    def test_roll_forward_beyond_nine_months_is_undated(self):
        # An 8-week course 55 days into its run must not be published as next
        # July's (it would stay "upcoming" forever).
        self.assertIsNone(wgis._parse_when_start("Tue Jul 14 7pm (LA) 8 classes", today=date(2026, 9, 7)))
        # …while a January class seen in October still rolls (86 days out).
        self.assertEqual(wgis._parse_when_start("Sat Jan 9 7pm", today=date(2026, 10, 15)),
                         "2027-01-09T19:00:00")

    def test_dayless_strings_are_undated(self):
        for when in ("Mondays 7pm (LA) drop in", "Sat 7pm (LA)", "TBA", "Ongoing"):
            self.assertIsNone(wgis._parse_when_start(when, today=date(2026, 9, 7)), when)

    def test_ordinal_day_still_counts_as_a_date(self):
        self.assertEqual(wgis._parse_when_start("Thu Jul 9th 7pm (2 hrs)", today=date(2026, 7, 22)),
                         "2026-07-09T19:00:00")

    def test_explicit_year_is_taken_as_written(self):
        self.assertEqual(wgis._parse_when_start("Thu Dec 18 2026 7pm", today=date(2027, 3, 1)),
                         "2026-12-18T19:00:00")

    def test_recent_past_class_keeps_its_year(self):
        # "Currently running" listings sit a few weeks back — no rollover.
        start = wgis._parse_when_start("Thu Jul 9 7pm (2 hrs)", today=date(2026, 7, 22))
        self.assertEqual(start, "2026-07-09T19:00:00")

    def test_december_class_seen_in_january_lands_last_year(self):
        # Mirror case: a December-started in-session class viewed in January
        # must roll BACK a year, not sit 11 months in the future.
        start = wgis._parse_when_start("Thu Dec 18 7pm (2 hrs)", today=date(2027, 1, 10))
        self.assertEqual(start, "2026-12-18T19:00:00")


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
        # Fixed `today`: the fixture carries no year, and with the real clock
        # the row rolls/undates itself as the calendar moves.
        classes = wgis._parse_classes(_WGIS_PAGE, "wgis_ny", "New York", today=date(2026, 7, 22))
        (c,) = classes
        self.assertEqual(c["id"], "wgis_ny/42")
        self.assertEqual(c["title"], "Drop-In")
        self.assertEqual(c["instructor"], "Jane Host")
        self.assertEqual(c["price"], "$20")
        self.assertTrue(c["is_full"])
        self.assertEqual(c["level"], "NYC Workshops")
        self.assertIn("-07-23T19:00:00", c["start"])

    def test_default_today_is_venue_local(self):
        with patch.object(wgis, "local_today", return_value=date(2026, 7, 22)):
            (c,) = wgis._parse_classes(_WGIS_PAGE, "wgis_ny", "New York")
        self.assertEqual(c["start"], "2026-07-23T19:00:00")

    def test_currently_running_section_is_undated(self):
        (c,) = wgis._parse_classes(_WGIS_RUNNING_PAGE, "wgis_la", "Los Angeles", today=date(2026, 9, 7))
        self.assertEqual(c["level"], "Currently Running")
        self.assertIsNone(c["start"])
        self.assertEqual(c["schedule"], "Tue Jul 14 7pm (LA) 8 classes")
        self.assertTrue(c["is_full"])   # "WAITLIST" spelling


if __name__ == "__main__":
    unittest.main()

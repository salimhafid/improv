# CONTEXT.md — complete as-built reference for Improv

Read this first in any new session. It captures how the product is built, how
it operates, and every non-obvious lesson learned. Companion files:
[TODO.md](TODO.md) (open items), [UCBapp.md](UCBapp.md) (generic playbook for
future apps), [ios/README.md](ios/README.md) (app architecture),
[ios/AppStore/metadata.md](ios/AppStore/metadata.md) (listing copy).

## What this is

**Improv** — a free, native iOS app aggregating live-comedy shows, classes,
and UCB talent across New York, Los Angeles, and Chicago. Zero-cost backend:
GitHub Actions scrapes on a cron and commits static JSON to this repo; the
app reads it from GitHub's raw CDN. No accounts, no analytics, no server.

- Repo: **github.com/salimhafid/improv** (public) — this directory.
- App Store: bundle `com.salimhafid.UCBShows`, display name **Improv**,
  team `8FKP6A38FJ`. **v1.1 approved and live** (July 2026). v1.2 (build 15)
  uploaded, pending version creation + submission in App Store Connect.

## System shape

```
GitHub Actions cron (.github/workflows/scrape.yml, "17 */3 * * *")
  → publish_static.py  (LOCAL_STORE_DIR=docs — the checkout IS the state)
      scraper.py    → docs/shows.json    (~2,600 shows, 11 sources)
      classes.py    → docs/classes.json  (~444 classes, 10 sources)
      talent.py     → docs/talent.json   (~2,086 people, ~1,586 bios)
  → commits changed feeds (bot commits keep the cron alive past GitHub's
    60-day-inactivity auto-disable)

App fetch URLs (ETag + max-age≈300 revalidation, ~5-min freshness):
  https://raw.githubusercontent.com/salimhafid/improv/main/docs/shows.json
  …/classes.json  …/talent.json
```

Key pipeline behaviors (aggregation.py shared loop + scraper.py / talent.py):
- **Per-source cadence**: `_SCRAPE_INTERVALS` — ucb_ny every 3h, everything
  else 24h. Sources not due carry last-good data from the previous payload;
  failures carry stale data (flagged) instead of wiping a source. Class
  sources all refresh daily (`classes.py`). Both aggregators run on
  `aggregation.run_sources()` — one loop, not two copies.
- **Empty-scrape guard**: a due fetch that returns 0 items while carry-over
  exists is treated like a failure (stale carry, scraped_at unchanged) — a
  200-OK page parsing to nothing is indistinguishable from a markup change.
  Adapters that KNOW empty is impossible raise instead (ucb page 1,
  annoyance calendar, playground ICS, brooklyn_cc link/collection mismatch,
  any failed magnet month).
- **Venue-local today**: upcoming filtering uses `common.local_today(city)`
  everywhere (aggregators AND adapters) — the runner's UTC date is already
  "tomorrow" from 5pm PT, which used to wipe same-night shows from the
  evening builds.
- **Crowdwork shows expand per-performance**: the shared adapter emits one
  item per future date in each show's `dates[]` (90-day cap, slug suffixed
  `/<YYYYMMDDHHMM>`), not just `next_date` — a weekly show is ~13 items.
- **Enrichment failure ≠ emptiness**: detail()/bio() return None on fetch
  failure and only successful fetches set `detail_done`/`bio_done`, so a
  Cloudflare burst is retried next run instead of cached as empty forever.
  Detail fetches dedupe by URL (Magnet's per-occurrence items share pages).
- **Tests**: `./run_tests.sh` = offline Python suite (tests/, synthetic
  fixtures, no network) + Swift logic harness (tests/ios/, compiled straight
  against app sources — no Xcode test target). Run it before committing.
- **Detail enrichment budget** (UCB + Magnet): 400 detail-page fetches/run,
  cached per URL via `detail_done` in the payload — converges, never
  re-fetches. Carries (description, cast, image, cast_members).
- **Talent bios**: budget 150/run (`TALENT_BIO_BUDGET`), `bio_done`
  carry-over by slug.
- **Never publish empty**: publish_static exits nonzero only if every show
  source failed.
- Workflow probe mode (`workflow_dispatch` input `probe`): from-scratch
  scrape into a throwaway dir, no commit — tests runner connectivity. A
  "successful" scheduled run can be 100% cadence carry-over; read per-source
  log lines ("scraped N" vs "not due"/"carried"), not exit codes.

## Sources (id · method · the quirks that matter)

| id | Theater | Method & quirks |
|---|---|---|
| ucb_ny / ucb_la | UCB NY / LA | WP Grid Builder listing (`ucbcomedy.com/shows/<city>`) + detail pages. **Paginated**: the grid serves 88 cards/page and `?_page=N` is server-rendered — walk pages until a short page (LA runs to 3 pages / ~185 shows; reading only page 1 once silently dropped 54% of LA). Images: strip WP `-WxH` suffix for full-size; detail `og:image` fills gaps. **Structured cast** from detail-page `/people/<slug>/` anchors inside `#main` (nav has team links — never scan outside #main); text "Featuring:" heuristic (multi-LINE — one name per line, stop at `—`/ticket words) is fallback only. Classes via the **Arlo registration API** (`ucbcomedy.arlo.co/api/.../eventsearch`, LOC_NY/LOC_LA tags); LOC_Online + satellite cities (Austin/Pittsburgh/Edinburgh) exist in Arlo but are deliberately unscoped. |
| brooklyn_cc | Brooklyn Comedy Collective | Squarespace (pre-existing adapter). |
| magnet | Magnet Theater | Month-calendar tables (3 months) + detail pages; **calendar has zero images — og:image from detail is the only artwork**. Classes: the all-classes-in-session index PLUS ~14 per-discipline `/class/<slug>/` pages (nav-discovered, same `div.class-holder` markup, deduped by WP id) — upcoming/enrolling sections only appear on the discipline pages. |
| wgis_ny / wgis_la | WGIS | Crowdwork slug `wgis` split by timezone offset. **wgis_ny = 0 shows is correct**: all Crowdwork items are Pacific — WGIS NY runs classes only (HTML `/nycclasses`, `/laclasses`; `/onlineclasses` deliberately unscoped). |
| annoyance | The Annoyance | **ThunderTix calendar-feed endpoint**: `GET theannoyance.thundertix.com/reports/calendar?start=<epoch>&end=<epoch>` → JSON, one call serves 6+ months (**180-day horizon**, ~450 perfs / ~80 productions). Per-production meta (desc/img/free) from event-page JSON-LD, `_WORKERS=3` — **ThunderTix 429s aggressively** (~400 reqs in 15 min triggers it; partial meta self-heals on the next daily run). A calendar failure/empty RAISES (aggregator carries last-good) — the old ~1-week JSON-LD fallback was removed 2026-08-08: replacing 180 carried days with 1 fresh week was strictly worse. Classes via Crowdwork slug `annoyancetrial`. |
| io_chicago | iO Theater | Crowdwork slug `iotheater` for shows AND classes. |
| second_city | The Second City | Crawl `/shows/chicago` index (~90 pages); each show page's `__NEXT_DATA__` has a **base64 `patronticketData`** blob with the full run (ISO UTC → convert to America/Chicago). Filter `custom.Event_City__c == "Chicago"` (Toronto leaks in). The show-finder page's `?dates=` filter is **client-side only** — never use it for enumeration. **180-day horizon** (blobs carry full on-sale runs incl. holiday shows — no extra requests). Stage from slug heuristic (mainstage/e.t.c./skybox). **Classes**: `/_next/data/<buildId>/find-a-class/chicago.json` (buildId from the find-a-class page's `__NEXT_DATA__`) → 86 class nodes, each with an Activenet section-rows JSON string (dates, weekly pattern, open seats) + hero (desc/image/price) — one item per open future section, 2 requests total. |
| logan_square | Logan Square Improv | Shared Crowdwork adapter, slug `lsi`, shows AND classes (their /events/ page is a Crowdwork widget on the same API). The old hand-rolled 28-day-window pagination was removed 2026-08-08 after verifying the bare endpoint returns a strict superset. `tags` are visibility flags, NOT genres. |
| playground | The Playground Theater | Site is **Canva**; show-calendar embeds a public **Google Calendar** — adapter reads the ICS (`calendar id c_eb31…@group.calendar.google.com`, hardcoded in sources/playground.py). Full RRULE expansion (dateutil) + EXDATE / RECURRENCE-ID overrides / CANCELLED. All shows free. No images (app's GeneratedCover handles). If they regenerate the calendar id, the source fails loudly and carries. |

**Talent** (talent.py + sources/ucb_talent.py): NY + LA + Teachers pages are
dt_team grids (`div.wf-cell[data-name]`, `/people/<slug>/`, headshot
data-src, `dt_team_category-dcm` class). The **DCM page is a WP Grid Builder
AJAX grid** — `/page/N` URLs all serve the same 30 people; the real protocol
is `POST /?wpgb-ajax=refresh&_load_more=<offset>` with the grid's form fields
(see `_fetch_dcm` in sources/ucb_talent.py) → full 1,228-person roster.
Groups: ny / la / teachers / dcm, merged by slug. DCM roster re-scrapes at
most daily.

## iOS app — what's beyond ios/README.md

- **Feed contract**: defensive decoding everywhere; `cast_members`
  [{name, slug}] enables exact talent matching (slug first, normalized name
  fallback). Saved I'm-Going shows persist as full encoded Show objects.
- **City timezones**: every show parses/day-buckets/labels in its own city's
  zone (City.timeZone). Never anchor to one city.
- **Talent UX**: cast chips on ucb_ny/ucb_la detail pages (coral = matched →
  bio; gray = unmatched → directory pre-searched); bio shows city tag
  (LA wins, else New York — DCM/teachers read as New York), scraped bio, and
  slug-matched Upcoming Shows; directory filters All/New York/Los Angeles
  are mutually exclusive (LA membership wins; NY includes DCM).
- **Calendar**: first Add-to-Calendar asks Apple vs Google, remembered in
  `@AppStorage("calendarProvider")`. Apple = write-only EventKit; Google =
  calendar.google.com/render TEMPLATE URL (routes to the Google app),
  venue-local times pinned with `ctz`.
- **Share**: UIActivityItemSource + custom LPLinkMetadata (title — date @
  time · theater · stage + poster). Rich preview applies when shared from
  the app; pasted-raw links fall back to the theater page's own OG
  (hosted OG interstitials were considered and deliberately skipped).
- **Reminders**: 1 hour before showtime; pending notifications rescheduled
  on every launch (migrates lead-time changes).
- **Onboarding**: none. A fresh install opens on UCB New York; theaters are
  picked in the sidebar and the city is always inferred from that selection.
- **DEBUG UITEST launch-env hooks** (Support/UITestSupport.swift + detail
  view): `UITEST_TAB` (0 Shows / 1 I'm Going / 2 Classes),
  `UITEST_PUSH_SOURCE=<source id>`, `UITEST_TALENT=directory|person|<name>`,
  `UITEST_SCROLL_CAST=1`, `UITEST_CALENDAR_DIALOG=1`, `UITEST_SHARE=1`,
  `UITEST_SIDEBAR=1`.

## Build & release runbook

```bash
cd ios
# bump build number (grep for current value first):
sed -i '' 's/CURRENT_PROJECT_VERSION = <N>;/CURRENT_PROJECT_VERSION = <N+1>;/g' UCBShows.xcodeproj/project.pbxproj
xcodebuild -project UCBShows.xcodeproj -scheme UCBShows \
  -destination 'generic/platform=iOS' -archivePath <path>/Improv.xcarchive \
  archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath <path>/Improv.xcarchive \
  -exportPath <path>/Upload -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates      # destination=upload → straight to ASC
```

- ExportOptions.plist (recreate if missing): method `app-store-connect`,
  teamID `8FKP6A38FJ`, signingStyle automatic, uploadSymbols true,
  destination `upload` (or `export` for a local .ipa).
- **Version rule**: a train closes once approved — 1.1 is closed; new
  uploads must carry MARKETING_VERSION ≥ 1.2. Both settings appear twice in
  the pbxproj (Debug+Release) — sed with /g.
- `ITSAppUsesNonExemptEncryption = NO` is baked in — no compliance prompt.
- **"Failed to Use Accounts"** on upload = Xcode's ASC session expired →
  user signs in via Xcode ▸ Settings ▸ Accounts, then retry (no rebuild).
- App record creation / version pages / Submit are **web-only** (no API).
  Listing copy lives in ios/AppStore/metadata.md; screenshots in
  ios/screenshots/appstore{,-65,-ipad}/ (6.9" 1320×2868 native; 6.5"
  1284×2778 derived via sips resize+crop; iPad 13" 2064×2752).

## Simulator verification recipe

```bash
xcrun simctl boot <udid>            # list: xcrun simctl list devices available
# no onboarding to skip; seed the selection directly if you need a non-default one
xcrun simctl spawn <udid> defaults write com.salimhafid.UCBShows selectedTheaters -array "ucb_ny"
xcrun simctl status_bar <udid> override --time "9:41" --batteryState charged --batteryLevel 100
SIMCTL_CHILD_UITEST_PUSH_SOURCE=ucb_ny xcrun simctl launch <udid> com.salimhafid.UCBShows
xcrun simctl io <udid> screenshot out.png
```

Gotchas learned the hard way:
- `simctl spawn defaults write` writes DEVICE-level prefs that **survive app
  uninstall** — `defaults delete <bundle>` to truly reset (e.g. to get back to
  the out-of-the-box UCB New York selection).
- Wait ~30s after boot or a system notification banner photobombs shots.
- After pushing feed changes, raw CDN needs ~30–60s; verification runs
  should uninstall+reinstall the app to drop stale caches.
- xcodebuild by-name simulator destinations fail if CoreSimulator version
  mismatches Xcode (fix: reboot/open Xcode once); `generic/platform=iOS
  Simulator` always compiles.

## Access & conventions

- **GitHub push**: user's fine-grained PAT, supplied in-conversation (not
  stored on disk; scratchpad copies get wiped — re-ask the user if needed).
  Remote `origin` = plain https; push with the token inline. Commits MUST
  use author email `1709833+salimhafid@users.noreply.github.com` (email
  privacy is on; real-email commits are rejected).
- The scrape bot commits every few hours → **always `git pull --rebase`
  before pushing; on docs/*.json conflicts take the newer feed (usually
  `git checkout --theirs` during rebase of your local commit)**.
- Xcode holds the Apple ID session; simulators available include iPhone 17
  Pro Max (6.9" shots) and iPad Pro 13-inch (M5).
- Scraping stack: python3 via `.venv/bin/python`, curl_cffi
  `impersonate="chrome"` everywhere (several sites block plain clients).
- **No AI co-author trailers on commits** (user decision 2026-07-22; the
  full history was rewritten to strip them — Salim is the sole human
  contributor).

## Money

$0/month for everything (public-repo Actions + raw CDN). The only recurring
cost anywhere is Apple's $99/yr developer program.

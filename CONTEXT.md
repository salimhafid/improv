# CONTEXT.md — complete as-built reference for Improv

Read this first in any new session. It captures how the product is built, how
it operates, and every non-obvious lesson learned. Companion files:
[TODO.md](TODO.md) (open items), [UCBapp.md](UCBapp.md) (generic playbook for
future apps), [ios/README.md](ios/README.md) (app architecture),
[ios/AppStore/metadata.md](ios/AppStore/metadata.md) (listing copy),
[PRIVACY.md](PRIVACY.md) (the App Store privacy policy).

## What this is

**Improv** — a free, native iOS app aggregating live-comedy shows, classes,
and UCB talent across New York, Los Angeles, and Chicago (plus UCB's online
classes). Zero-cost backend: GitHub Actions scrapes on a cron and commits
static JSON to this repo; the app reads it from GitHub's raw CDN. No server
of ours, no analytics. The only "backend" beyond the repo is Apple's: a
CloudKit public database that the class-alert watcher writes to, iCloud
key-value storage that mirrors the user's own settings, and APNs.

- Repo: **github.com/salimhafid/improv** (public) — this directory.
- App Store: bundle `com.salimhafid.UCBShows`, display name **Improv**,
  team `8FKP6A38FJ`. v1.1 approved and live July 2026; the 1.2, 1.3 and
  1.4 trains closed on approval (2026-08-08, 2026-08-27, and by 2026-09-07
  when App Store Connect showed 1.4 "Ready for Distribution"). The project
  is at **MARKETING_VERSION 1.5, CURRENT_PROJECT_VERSION 25**; builds 1.5
  (24) and 1.5 (25) were uploaded on 2026-09-07, and **version 1.5 with
  build 25 was submitted for review the same day** (state
  WAITING_FOR_REVIEW) through the App Store Connect API via
  `tools/asc_release.py`. The next app change must bump the build past 25.
- Accounts: none of ours. The app offers an **optional UCB student sign-in**
  (ucbcomedy.com, inside a web view) for reserving free student tickets — see
  "UCB session engine" below and PRIVACY.md.

## System shape

```
GitHub Actions cron (.github/workflows/scrape.yml, "23 * * * *" — hourly)
  → publish_static.py  (LOCAL_STORE_DIR=docs — the checkout IS the state)
      scraper.py    → docs/shows.json    (11 sources; 2,182 shows in the 2026-09-05 feed,
                                          541 of them a frozen Second City carry — see watchlist)
      classes.py    → docs/classes.json  (11 sources incl. ucb_online; 402 classes)
      talent.py     → docs/talent.json   (UCB directory; 1,735 people, 1,585 bios)
  → commits changed feeds (bot commits also keep the cron alive past GitHub's
    60-day-inactivity auto-disable)

Class-alert watcher (.github/workflows/class-watch.yml + 3 kicker crons)
  → watcher.py scans class sources every ~10 min, writes CloudKit `ClassAlert`
    records; devices receive them as pushes via their CKQuerySubscriptions.
    State on the orphan branch `class-watch-state`. (Section below.)

tests.yml: push to main (ignoring docs/**) → Python unit tests only.
           The Swift harness (./run_tests.sh) runs locally only.

App fetch URLs (default URLSession cache policy → ETag/304 revalidation):
  https://raw.githubusercontent.com/salimhafid/improv/main/docs/shows.json
  …/classes.json  …/talent.json
```

The hourly cron replaced `17 */3 * * *` on this branch: GitHub starves a
3-hourly cron on a quiet repo (runs landed hours late or were skipped; the
delivered cadence from 2026-08-27 was 2–5 runs/day). Extra ticks are ~1-minute
no-ops because the aggregator's own per-source cadence carries everything that
isn't due.

Key pipeline behaviors (aggregation.py shared loop + scraper.py / classes.py /
talent.py):
- **Per-source cadence**: `_SCRAPE_INTERVALS` — ucb_ny every 3h, every other
  show source 24h (`scraper.py`); every class source daily (`classes.py`);
  each talent group daily (`talent.py`). All with a 30-minute early-tick
  grace. Sources not due carry last-good data from the previous payload;
  failures carry stale data (flagged `stale: true`) instead of wiping a
  source. Both show and class aggregators run on `aggregation.run_sources()`
  — one loop, not two copies; talent.py mirrors the contract with its own
  per-group loop.
- **A failed source is due on every run**: `carry()` keeps the previous
  `scraped_at`, and once that is `null` (Second City today) the source is
  retried every tick — hourly, now. Second City is a ~91-page crawl, so a
  broken adapter costs ~91 requests/hour until fixed.
- **Empty-scrape guard**: a due fetch that returns 0 items while carry-over
  exists is treated like a failure (stale carry, scraped_at unchanged) — a
  200-OK page parsing to nothing is indistinguishable from a markup change.
  Adapters that KNOW empty is impossible raise instead (ucb page 1,
  annoyance calendar, playground ICS, second_city index/class payload,
  brooklyn_cc link/collection mismatch, any failed magnet month). Crowdwork
  `data: []` does not raise (the aggregator guard covers it).
- **Carried rows are filtered one at a time** (`_filter_carried`): a corrupt
  row drops itself (logged) instead of aborting the whole source's carry.
- **Venue-local today**: upcoming filtering uses `common.local_today(city)`
  everywhere (aggregators AND adapters) — the runner's UTC date is already
  "tomorrow" from 5pm PT, which used to wipe same-night shows from the
  evening builds. `CITY_TZ["Online"]` is America/New_York (UCB schedules
  online classes in Eastern time).
- **Crowdwork shows expand per-performance**: the shared adapter emits one
  item per future date in each show's `dates[]` (90-day cap, slug suffixed
  `/<YYYYMMDDHHMM>`, occurrences deduped on wall-clock time), not just
  `next_date` — a weekly show is ~13 items. Classes take the first future
  date of `[next_date] + dates[]`. Crowdwork `tags` are mostly
  visibility/marketing flags; only a genre allow-list (`_GENRE_TAGS`) becomes
  `comedy_types`, while the class `level` still reads the raw first tag
  (that is where iO/Annoyance levels live).
- **Enrichment failure ≠ emptiness**: detail()/bio() return None on fetch
  failure (and UCB `detail()` returns None when the page has no `#main`), and
  only successful fetches set `detail_done`/`bio_done`, so a Cloudflare burst
  is retried next run instead of cached as empty forever. Detail fetches
  dedupe by URL (Magnet's per-occurrence items share pages).
- **Detail enrichment budget** (UCB + Magnet): 400 detail-page fetches/run
  (`_DETAIL_BUDGET`, 8 workers) AND an 8-minute wall-clock deadline
  (`_DETAIL_DEADLINE`, measured from the start of `aggregate()`): past it no
  new fetch starts and the rest stay unflagged for next run. Cached per URL
  via `detail_done`. Carries (description, cast, image, cast_members) and
  fills an empty listing `excerpt` from the description (240 chars, cut at a
  word). `REFRESH_DETAILS=1` forces every show source due and re-fetches
  details (shows only; via `run_sources(force=True)`, so a source that fails
  on that run keeps its last-good `scraped_at`).
- **Talent roster**: three dt_team pages (ny / la / teachers) + the DCM
  load-more endpoint, each group on its own daily stamp (`scraped_at` per
  summary row). A group that fails carries stale and is retried next tick,
  but a sweep in which EVERY attempted group failed sets
  `roster_attempted_at` and backs off for 6 h (`_ROSTER_BACKOFF`) — the host
  is blocking us, so don't hammer it hourly. A page that parses to < 60 % of
  its previous head-count is treated as a failed fetch (`_SHRINK_RATIO`); DCM
  additionally requires 80 % of the total the endpoint reports. Bios: budget
  150/run (`TALENT_BIO_BUDGET`, parsed leniently), 8 workers, 5-minute
  deadline, `bio_done` carry-over by slug.
- **Never publish empty**: `publish_static.py` exits nonzero if no show source
  is *healthy* (`ok` AND `count > 0` — a legitimately empty `wgis_ny` cannot
  vouch for an empty feed), or if any feed could not be written (including an
  unset `LOCAL_STORE_DIR`). An empty classes or talent payload keeps the
  previous file rather than failing the run.
- **Tests**: `./run_tests.sh` = offline Python suite (tests/, synthetic
  fixtures, no network; `REFRESH_DETAILS` unset) + Swift logic harness
  (tests/ios/LogicTests.swift, compiled straight against the Foundation-only
  app sources — no Xcode test target). Run it before committing. CI runs
  only the Python half. Python locally is 3.9 (`.venv`), CI is 3.12 —
  `requirements.txt` states the ≥ 3.9 floor.
- Workflow probe mode (`workflow_dispatch` input `probe`): from-scratch
  scrape into a throwaway dir, no commit — tests runner connectivity. A
  "successful" scheduled run can be 100% cadence carry-over; read per-source
  log lines ("scraped N" vs "not due"/"carried"), not exit codes.
- **HTTP**: everything goes through `common._request` (curl_cffi):
  impersonation rotates `chrome → chrome120 → safari` across the 3 attempts;
  404/410 stop after one attempt (403 does NOT — Cloudflare 403s a rejected
  fingerprint, which is what the rotation exists for); a 202 is treated as a
  challenge; the first bad body per (host, status) is logged once at WARNING
  (`ucb.common`) so the Actions log captures what ucbcomedy.com actually
  serves; `post_json` exists for the DCM load-more endpoint.

## Sources (id · method · the quirks that matter)

| id | Theater | Method & quirks |
|---|---|---|
| ucb_ny / ucb_la | UCB NY / LA | WP Grid Builder listing (`ucbcomedy.com/shows/<city>`) + detail pages. **Paginated**: `?_page=N` is server-rendered; the walk stops when a page adds nothing new (out-of-range pages re-serve page 1), capped at `_MAX_PAGES = 8` — deliberately NOT a page-size heuristic (88 cards/page today), so a smaller grid can't silently truncate. Reading only page 1 once dropped 54% of LA (134 LA shows in the current feed). Images: strip WP `-WxH` suffix for full-size; detail `og:image` fills gaps. **Structured cast** from detail-page `/people/<slug>/` anchors inside `#main` (nav has team links — never scan outside #main; no `#main` → `detail()` returns None and the page is retried); text "Featuring:" heuristic (one name per line, or a comma list of short names on the label line; stop at `—`/ticket words; "Podcast:" does not match) is fallback only. Text caps (400 cast / 2000 description) cut at a word with "…". Classes via the **Arlo registration API** (`ucbcomedy.arlo.co/api/.../eventsearch`): LOC_NY → `ucb_ny`, LOC_LA → `ucb_la`, **LOC_Online → `ucb_online`** (city "Online", 16 items); the paged walk is memoised per run (including a failure) so the three passes cost one walk; Arlo `Summary` becomes the description only when it isn't a "Category: …" line. Satellite cities (Austin/Pittsburgh/Edinburgh) are still deliberately unscoped. |
| brooklyn_cc | Brooklyn Comedy Collective | Squarespace Events collection via `?format=json`. Squarespace categories are **rooms** (Eris Mainstage / Deep Space / Pig Pen…) → `venue`/`venues`, `comedy_types=[]`. "No show…" closure notices skipped. Classes: instructor after ` w/`; a date in the product title ("(Saturday, September 12th, 2026)") becomes `start` so drop-ins age out; multi-week "(Aug-Oct '26)" titles stay undated. |
| magnet | Magnet Theater | Month-calendar tables (`MONTHS_AHEAD = 3`) + detail pages; **calendar has zero images — og:image from detail is the only artwork**. `detail()` reads `[itemprop="description"]` first, falling back to `#content` cut at the address line / ticket table. Card years are inferred (same-year unless > 240 days stale or > 125 days ahead); href-less cards skipped. Classes: the all-classes-in-session index PLUS per-discipline `/class/<slug>/` pages (nav-discovered, capped at `_MAX_DISCIPLINE_PAGES = 20`, same `div.class-holder` markup, deduped by WP id) — upcoming/enrolling sections only appear on the discipline pages. |
| wgis_ny / wgis_la | WGIS | Crowdwork slug `wgis` split by the event's `timezone` name (UTC offset as fallback). **wgis_ny = 0 shows is correct**: all Crowdwork items are Pacific — WGIS NY runs classes only (HTML `/nycclasses`, `/laclasses`; `/onlineclasses` deliberately unscoped). Class dates carry no year: month + day required (else undated); "Currently Running"/"in session" sections publish undated; a date > 45 days behind rolls to next year unless that lands > 270 days out (then undated — an in-session course); an explicit year is taken as written. `is_full` recognises full / sold-out / waitlist. |
| annoyance | The Annoyance | **ThunderTix calendar-feed endpoint**: `GET theannoyance.thundertix.com/reports/calendar?start=<epoch>&end=<epoch>` → JSON, one call serves the **180-day horizon** (353 perfs in the current feed). Per-production meta (desc/img/free) from event-page JSON-LD, `_WORKERS=3` — **ThunderTix 429s aggressively** (partial meta self-heals on the next daily run). A calendar failure/empty RAISES (aggregator carries last-good) — the old ~1-week JSON-LD fallback was removed 2026-08-08: replacing 180 carried days with 1 fresh week was strictly worse. Default venue "Annoyance Theatre". Classes via Crowdwork slug `annoyancetrial`. |
| io_chicago | iO Theater | Crowdwork slug `iotheater` for shows AND classes. |
| second_city | The Second City | Crawl `/shows/chicago` index (~90 pages, 6 workers); each show page's `__NEXT_DATA__` has a **base64 `patronticketData`** blob with the full run (ISO UTC → America/Chicago). **Toronto guard**: an instance is skipped only when `custom.Event_City__c` is present AND not "Chicago" — PatronTicket stopped sending the field in August 2026 and the old `== "Chicago"` test rejected every showtime (the source was frozen from 2026-08-12 until this fix; see watchlist). Stage from the page's own show record `showAttributes.venue[].name` (city suffix stripped), slug heuristic (mainstage/e.t.c./skybox) as fallback; description from the blob's `description`/`detail`, else `showAttributes.description` — never the first `description` in tree order (that's the parking paragraph). Rating/policy `showTags` (Rated R, 21+, drink minimum, Guest Performance) are not `comedy_types`. The show-finder's `?dates=` filter is **client-side only** — never use it for enumeration. **180-day horizon**. **Classes**: `/_next/data/<buildId>/find-a-class/chicago.json` (buildId from the find-a-class page's `__NEXT_DATA__`) → class nodes, each with an Activenet section-rows JSON string (dates, weekly pattern, open seats) + hero (desc/image/price) — one item per open future section (53 in the current feed), 2 requests total. |
| logan_square | Logan Square Improv | Shared Crowdwork adapter, slug `lsi`, shows AND classes (their /events/ page is a Crowdwork widget on the same API). The old hand-rolled 28-day-window pagination was removed 2026-08-08 after verifying the bare endpoint returns a strict superset. |
| playground | The Playground Theater | Site is **Canva**; show-calendar embeds a public **Google Calendar** — adapter reads the ICS (`calendar id c_eb31…@group.calendar.google.com`, hardcoded in sources/playground.py), **62-day horizon**. RRULE expansion (dateutil) + EXDATE / RECURRENCE-ID overrides / CANCELLED; date-only and Z-form `UNTIL` both handled (a regex used to double a Z-form UNTIL and drop the series); `TZID=` honoured; `VALARM` blocks ignored; `DTEND` → `end`. One-off all-day entries ("Happy Labor Day") are skipped as calendar notes; recurring all-day series and their overrides are kept. All shows free. No images (app's GeneratedCover handles). If they regenerate the calendar id, the source fails loudly and carries. |

**Talent** (talent.py + sources/ucb_talent.py): NY + LA + Teachers pages are
dt_team grids (`div.wf-cell[data-name]`, `/people/<slug>/`, headshot
data-src) read by `fetch_page`. The **DCM page is a WP Grid Builder AJAX
grid** — `/page/N` URLs all serve the same 30 people; the real protocol is
`POST /?wpgb-ajax=refresh&_load_more=<offset>` with the grid's form fields
(`_dcm_batch`, driven by `fetch_dcm_roster`; the first batch supplies the
total and is fatal, later batches that fail log and return `[]` and the 80 %
completeness check decides). Names are HTML-unescaped. Groups: ny / la /
teachers / dcm, merged by slug (880 DCM people in the current feed; la 903,
ny 448, teachers 134). Live status: see the watchlist — all four groups have
failed on every recent run.

## Class-alert watcher (watcher.py + .github/workflows/class-watch*.yml)

Pushes "new class posted" notifications with no server of ours: a GitHub
Actions job scans the class sources, and new classes become records in the
app's **CloudKit public database**; each iCloud user's `CKQuerySubscription`s
turn those into APNs pushes on their registered devices.

- **The chain** (`class-watch.yml`, `workflow_dispatch` only, `mode=chain`
  by default): GitHub delays *scheduled* runs by hours on a quiet repo but a
  running job keeps its clock, so one job loops "scan, commit state, sleep
  600 s" for `CHAIN_BUDGET_MIN=330` minutes (job `timeout-minutes: 355`) and
  then, `if: always()`, dispatches its own successor (3 attempts). Each
  iteration runs `python watcher.py --ucb --all-if-stale 20`: UCB's Arlo
  catalog every iteration, every other school only when the newest non-UCB
  state stamp is > 20 h old (so roughly daily). Concurrency group
  `class-watch-chain` for the chain; one-shot modes (including diagnostics) get
  a per-run group so they are not cancelled by the chain's self-dispatch.
- **Kickers** (`class-watch-kick-{1,2,3}.yml`, crons `4,24,44` / `11,31,51`
  / `17,37,57` past the hour): restart-only. `gh run list` — if no chain run
  is in progress/queued, `gh workflow run class-watch.yml -f mode=chain`;
  otherwise exit. Three staggered odd-minute crons because :00 is the worst
  slot in GitHub's scheduler lottery.
- **State**: `class-watch.json` at the root of the orphan branch
  `class-watch-state` (checked out into `state-branch/`, `WATCH_STATE` points
  at it; the bare default `state/class-watch.json` is for local runs).
  `{ "<school>": {"ids": [...], "updated": iso}, "_pending_alerts": [...] }`.
  Committed after every iteration by `class-watch-bot` (rebase-on-top on a
  rejected push) — ~144 commits/day on that branch. If the state checkout
  fails, the job baselines from scratch ONLY when `git ls-remote` positively
  reports no such branch (exit 2); any other failure aborts, because an empty
  state would silently baseline every school and then overwrite the real one.
- **Scan → diff**: `scan_ucb()` = one Arlo pull split by `LOC_*` tag into
  `ucb_ny / ucb_la / ucb_online`, each class tagged with EVERY matching
  `CTG_*`/`FRQ_*` category (`UCB_CATEGORY_TAGS`; first match = primary
  `category`); `scan_others()` = every non-UCB `CLASS_SOURCES` adapter (a
  raising adapter is skipped, state untouched). `diff_and_alert`: a school
  with no prior state is **baselined silently**; a scan that comes back
  **empty for a school that had classes is treated as a failed scan** (prior
  ids kept, nothing alerted, `updated` not bumped) so the next good scan
  doesn't alert on every class; a corrupt state entry is re-baselined. New
  UCB classes are bundled per (school, category set); other schools get one
  bundle per school (`category "all"`). `compose()` builds `pushTitle`
  ("New Improv classes at UCB New York") and `pushBody` (up to three titles,
  capped at 170 chars).
- **CloudKit record**: `POST https://api.apple-cloudkit.com/database/1/
  iCloud.com.salimhafid.UCBShows/<env>/public/records/modify`, record type
  `ClassAlert`, fields `school`, `category`, `categories` (STRING_LIST),
  `count`, `pushTitle`, `pushBody`, `classIDs`. Written to BOTH
  environments by default (`CLOUDKIT_ENVS=development,production`) so dev
  and App Store builds both hear it. Signed per Apple's server-to-server
  spec: ECDSA P-256 over `"<ISO date>:<base64 sha256(body)>:<subpath>"`
  (`cryptography`, now in requirements.txt).
- **Secrets** (repo Actions secrets, set 2026-08-15): `CLOUDKIT_KEY_ID`
  (development key), `CLOUDKIT_KEY_ID_PROD`, `CLOUDKIT_PRIVATE_KEY` (PEM).
  Keys come from CloudKit Console → server-to-server keys; rotate by
  uploading a new public key there and replacing the secrets. Missing
  credentials leave affected alerts pending and make the run fail; they
  never imply a successful delivery. A production-only key can serve
  production independently of the development key.
- **Retry and acknowledgement rules**: `send_alerts` runs BEFORE
  `save_state`. Every requested record name needs exactly one successful
  acknowledgement; a 200 response with missing, duplicate, unrelated, or
  failed record acknowledgements leaves the affected alerts pending.
  Pending alerts carry the environments still owed and only retry there.
  Temporarily removing an environment from `CLOUDKIT_ENVS` preserves its
  pending obligations. Missing credentials and malformed keys also preserve
  alerts. Accepted writes log the record name, school, and categories.
  All unacknowledged alerts stay in `_pending_alerts`; a backlog over 50
  warns instead of discarding older alerts. Writes use batches of at most
  200 operations per environment, so a larger backlog can drain and one
  failed batch does not block later batches. A failed UCB scan keeps its
  school state while still allowing pending deliveries to retry. Pending
  deliveries or a failed scan make `main()` exit nonzero; the chain warns
  and still commits state. Delivery remains **at least once**: uncertain
  responses or state-push failures can produce duplicate records/pushes.
- **Preview**: `python watcher.py --ucb --dry-run` scans and prints proposed
  alerts without CloudKit writes or state changes, including no baseline
  write and no consumption of pending alerts. Supply `WATCH_STATE` to preview
  against a copy of the real state; an unknown school baselines silently.
  `--dry-run` cannot be combined with the writing `--test` mode.
- `--test` writes and deletes a probe record in **development only**;
  `--test-prod` opts production in. `mode=test` in the workflow therefore
  tests development only.
- **Risk to know about**: a job that sleeps in a loop ~24 h/day and
  re-dispatches itself is a serverless cron running on Actions; GitHub's
  Actions usage policy lists that kind of use as prohibited. Whether it
  would ever be enforced against this repo is unknowable from here — if the
  workflow is ever disabled by GitHub, alerts stop and this is why.

### Production UCB subscription failure — 2026-09-08

The failure reproduced at **subscription creation**, after record delivery
and query checks had succeeded. [Diagnostic run 34274103807](https://github.com/salimhafid/improv/actions/runs/34274103807)
found UCB NY class IDs `42353` and `42333` in both CloudKit environments and
successfully queried `school == ucb_ny AND categories CONTAINS improv`.
[Subscription probe 34274450133](https://github.com/salimhafid/improv/actions/runs/34274450133)
then created and removed the same query shape in development, but production
rejected creation with `BAD_REQUEST: attempting to create a subscription in
a production container`.

**A working query index does not prove that production accepts the subscription
type.** CloudKit's schema includes subscription types as well as record types
and security roles ([Apple's schema definition](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/Glossary/Glossary.html)).
Creating the development subscription establishes its template; promote that
template with the development schema to production. Checking or deploying
field indexes alone is not sufficient evidence that this step happened.
CloudKit Console subsequently reported **Changes Deployed**. At
`2026-09-08T20:27:24Z`, [probe run 34274880391](https://github.com/salimhafid/improv/actions/runs/34274880391)
accepted and removed the exact UCB subscription in **both development and
production**, verifying that the production subscription gate was repaired.
The user confirmed receipt of **Improv notification test** on their phone on
2026-09-08. [Owner-only production test 34275363613](https://github.com/salimhafid/improv/actions/runs/34275363613)
created the matching alert at `20:32:32Z`. That run's failure was its original
record-cleanup request, not alert creation; the subscription was removed, and
[cleanup run 34275715138](https://github.com/salimhafid/improv/actions/runs/34275715138)
removed the diagnostic record after the cleanup fix. Production push delivery
to the physical device is verified.

This temporary test subscription is separate from the user's saved choices.
[Diagnostic run 34276008696](https://github.com/salimhafid/improv/actions/runs/34276008696)
at `20:38:56Z` still found zero production subscriptions for the server key's
owner. The user was asked to open Class Alerts and confirm the enabled UCB
schools/categories so the app can reconcile them. The watcher is running and
its first scan after the fix completed at `20:33:40Z` with no pending alerts.

After the user enabled alerts, production Console logs showed repeated native
iPhone `SubscriptionCreate` requests failing with `BAD_REQUEST` at
`20:41:37–20:41:56Z`. The native and server requests used the same account.
The expanded [probe run 34276819038](https://github.com/salimhafid/improv/actions/runs/34276819038)
identified a second missing template: **school-only** subscriptions, used for
non-UCB schools, still failed in production while legacy scalar-category and
current list-category UCB subscriptions succeeded. The school-only template
was then deployed. [Full probe 34276958719](https://github.com/salimhafid/improv/actions/runs/34276958719)
accepted and cleaned up **all three query shapes in both environments** at
`20:48:58Z`. The user was asked to foreground the app again after this second
deployment; registration of the app's real saved choices remains to be checked.
Always probe every shape the app can send, not only the UCB predicate.

The workflow exposes separate checks using the existing Actions secrets:

| Mode | Action | What success establishes |
|---|---|---|
| `diagnose` | Read-only school/category record queries and a best-effort subscription count for the server key's owner. No records, subscriptions, or state are written. | Server authentication and query support; counts do not describe every app user. |
| `probe-subscription` | Creates and deletes uniquely named temporary subscriptions for each shipped query shape: school-only, school plus scalar category (legacy UCB), and school plus list-category membership (current UCB). All use `school == __improv_diagnostic__`. Creates no class records and sends no pushes. Development may learn the templates. | All supported app versions' query shapes can be registered in each environment; cleanup must also succeed. |
| `test-push-owner` | Sends one real production push using a temporary subscription and matching `ClassAlert` for a UUID-specific diagnostic school. Existing school-specific subscriptions cannot match it. Both temporary objects are cleaned up. The CLI requires `--send`; selecting this workflow mode invokes it explicitly. | CloudKit accepted the test and cleanup completed. Only the server key owner's registered app devices are targeted; the person must confirm receipt. |
| `cleanup-owner-test` | Removes only the diagnostic UUID record named by the `diagnostic_record` workflow input, using `forceDelete`. Rejects normal alert names and creates nothing. | A leftover diagnostic record is removed or already absent; no new push is sent. |

Dispatch against a ref containing these modes (use `main` after merge):

```bash
ALERTS_REF=main
gh workflow run class-watch.yml --ref "$ALERTS_REF" -f mode=diagnose
gh workflow run class-watch.yml --ref "$ALERTS_REF" -f mode=probe-subscription
```

Recovery sequence: inspect both runs; in CloudKit Console select
`iCloud.com.salimhafid.UCBShows`, review the development-to-production schema
deployment including the learned subscription template, and deploy it. Rerun
`probe-subscription` and require production acceptance plus cleanup. A cleanup
failure prints the exact temporary subscription ID to remove; do not delete
the user's `alert/` subscriptions. If production still rejects the same shape,
preserve the error and investigate the container instead of declaring recovery.

Finally foreground the signed App Store/TestFlight app, open Class Alerts,
confirm the intended school/categories and absence of a subscription error,
and verify receipt on that device. The app reconciles on foreground; schema
promotion alone does not register a user's previously failed subscriptions.
The first two modes do not test APNs receipt or replay historical `ClassAlert`
records; the subscriptions fire on record creation. For an explicitly requested
test to the server key owner, use `mode=test-push-owner` (or
`python tools/test_class_alert_push.py --send` with the proper credentials).
It creates no real-school alert, changes no preferences or watcher state, and
reports its generated cleanup IDs. A successful run still needs human receipt
confirmation and does not prove another user's subscriptions are configured.
Avoid inserting a normal UCB class record merely to test delivery, because it
matches real subscribers.

## iOS app — what's beyond ios/README.md

- **Feed contract**: defensive decoding everywhere (`try?` per scalar, lossy
  arrays for `venues`/`comedy_types`/`cast_members`; an empty
  `source`/`org`/`city` takes the same fallback as a missing one);
  `cast_members` [{name, slug}] enables exact talent matching (slug first,
  normalized name fallback — `nameKey` folds diacritics and ø/ł/ß/æ/œ).
  Saved I'm-Going shows persist as full encoded Show objects. Shows whose
  start is before `min(start of today in the venue zone, now − 6 h)` are
  pruned from the feed display (undated shows kept). `DateUtils.parse`
  accepts only the feed's naive 10/16/19-char forms.
- **Cities**: `City` is `newYork | chicago | losAngeles | online`. **Online**
  is a pseudo-city for `ucb_online` (`hasShows: false`, so never a sidebar
  section; Eastern time): the catalog has 12 entries for 11 theaters, and
  `classScope` adds `ucb_online` whenever `ucb_ny` or `ucb_la` is selected,
  so the Classes tab shows a "UCB Online" folder (last, after the selected
  city's schools; Improv 101–401 rank as Core Curriculum there too).
  `SourceCatalog.isUCB(id)` is the one "is this UCB" helper (talent
  directory, class alerts, student reserve).
- **City timezones**: every show parses/day-buckets/labels in its own city's
  zone (City.timeZone). Never anchor to one city.
- **Tabs**: Shows (0) · **Tickets** (1 — Student ID and reserved tickets on
  top, the hearted "I'm Going" list below) · Classes (2).
- **Talent UX**: cast chips on UCB detail pages (coral = matched → bio; gray
  = unmatched → directory pre-searched); bio shows city tag (LA wins, else
  New York — DCM/teachers read as New York), scraped bio, and slug-matched
  Upcoming Shows; directory filters All/New York/Los Angeles (LA membership
  wins; NY = everyone whose city label is New York). `TalentStore.phase`
  (`loading/loaded/offline/failed`) drives a Try Again / offline banner.
- **Calendar**: first Add-to-Calendar asks Apple vs Google, remembered in
  `@AppStorage("calendarProvider")`. Apple = write-only EventKit; Google =
  calendar.google.com/render TEMPLATE URL (routes to the Google app; title,
  venue, excerpt and show URL leave the device in that URL), venue-local
  times pinned with `ctz`, `+&=` percent-encoded.
- **Share**: UIActivityItemSource + custom LPLinkMetadata (title — date @
  time · theater · stage + poster). Rich preview applies when shared from
  the app; pasted-raw links fall back to the theater page's own OG
  (hosted OG interstitials were considered and deliberately skipped).
- **Reminders**: 1 hour before showtime (`ReminderPlan.lead`), rescheduled
  on every launch (migrates lead-time changes) and re-armed when permission
  is granted by any feature. Identifiers: `<show.id>` for hearts,
  `ticket/<ticket.id>` for tickets. **One reminder per show**: `TicketStore`
  publishes coverage and the heart's reminder stands down (the ticket's tap
  opens the QR). Ids that vanish from `going.json` (iCloud reload) have
  their pending notifications cancelled. Tapping a heart reminder deep-links
  to the show in the Tickets tab (`AppState.openShowID`); a ticket reminder
  opens that ticket (`openTicketID`); a class alert opens the Classes tab.
- **Onboarding**: none. A fresh install opens on UCB New York; theaters are
  picked in the sidebar and the city is always inferred from that selection.
- **Filters**: persisted as JSON under `filters` (lenient decoder, unknown
  values fall back to defaults); `reconcileFilters` drops a venue/type no
  longer offered in scope, clears the venue when fewer than two venues are
  offered (the picker hides), and does nothing while the scope has zero shows
  (a temporarily empty carry must not wipe persisted filters).
- **Caches**: feed caches in Application Support (`<feed>.cache.json`, no
  TTL — freshness comes from the network refresh; pull-to-refresh uses
  `.reloadRevalidatingCacheData`); an undecodable file is moved aside as
  `<name>.bak-<unix seconds>.json`. `URLCache.shared` = 32 MB / 256 MB for
  posters (`PosterPipeline` downsamples with ImageIO, `NSCache`s the thumbs,
  and coalesces identical in-flight URLs).
- **iCloud KVS sync** (`CloudSync`, `NSUbiquitousKeyValueStore`, entitlement
  `ubiquity-kvstore-identifier`): defaults keys `selectedTheaters`,
  `filters`, `classAlertPrefs`, `calendarProvider` and files `going.json`,
  `tickets.json` (as `file/<name>`). `bootstrap()` runs before any store is
  built and adopts the cloud copy only where nothing local exists; local
  changes push (last writer wins, never deletes cloud state; defaults pushes
  are held until the initial sync lands or a 5 s fallback); external changes
  are written to disk and `fileDidChange` reloads GoingStore/TicketStore
  live; class-alert prefs apply live (the store observes `UserDefaults`);
  theater selection and filters apply on next launch. `AccountChange` /
  `QuotaViolationChange` reasons are logged and not adopted. Device-local
  only: `classAlertSyncPending`.
- **Class alerts (app side)**: `ClassAlertsStore.Prefs {master, schools,
  ucb: [school: Set<category>], version}` under `classAlertPrefs` (lenient
  decoder; a blob without `version` decodes as 0 and is migrated once; a
  fresh `Prefs()` is already v1). Enabling a UCB school seeds
  `improv, improv_electives, featured_programs`. Desired subscriptions:
  `alert/<school>/all` (`school == %@`) for other schools,
  `alert/v2/<school>/<category>` (`school == %@ AND categories CONTAINS %@`)
  per UCB category; `CKQuerySubscription(recordType: "ClassAlert",
  firesOnRecordCreation)` with `titleLocalizationKey CA_TITLE` /
  `alertLocalizationKey CA_BODY` bound to `pushTitle`/`pushBody`
  (`Localizable.strings` at the bundle root holds the `"%@"` passthroughs —
  the first real `en.lproj` localisation must migrate it). Reconcile
  (`syncSubscriptions`) is coalesced, loops until prefs stop moving,
  surfaces per-item CloudKit failures as `syncIssue`, and a persisted dirty
  flag (`classAlertSyncPending`) makes `armOnLaunch` retry a reconcile that
  failed offline — including the delete-everything reconcile after the
  master switch goes Off. `armOnLaunch` (launch + every foreground) never
  prompts; `armIfNeeded` (sheet open) does. `PushRegistrationDelegate`
  surfaces APNs registration failures. Entitlements: `aps-environment`,
  iCloud container `iCloud.com.salimhafid.UCBShows`, CloudKit, KVS.
- **UCB session engine** (`UCBSession`): UCB has no API and sits behind
  Cloudflare Turnstile + JA3 binding, so ONE permanent off-screen `WKWebView`
  over a named `WKWebsiteDataStore` (fixed UUID) is both the login surface's
  cookie jar and the API client — every authenticated call runs as injected
  JS inside it. The sign-in sheet (`UCBSignInView`) opens UCB's real
  `/my-account/` login in a second web view over the SAME data store, ticks
  WooCommerce's "Remember me" (else the auth cookie is a session cookie and
  users got signed out), and treats the sheet as signed in only when a page
  shows a positive dashboard marker (`.woocommerce-MyAccount-navigation` or
  `.ucb-student-id`) — not merely "no login form" (the lost-password page and
  Cloudflare interstitials used to fire it). Ops are serialized behind an
  async lock, bounded by a 20 s navigation gate, stand down while the login
  sheet owns the web view, and re-check cancellation after acquiring the
  lock. API: `refresh() → RefreshOutcome (signedIn(snapshot) | signedOut |
  unknown)`, `claimAvailability(showURL:)`, `reserve(showURL:) → ActionResult`
  (POST `admin-ajax.php` `ucb_student_claim`), `release(order:nonce:) →
  ActionResult`, `signOut()` (wipes the data store). `unknown` never wipes
  the cached wallet.
- **Account + tickets**: `UCBAccountStore` holds `phase`, `name`, `eligible`,
  `freeRemaining`, `isConfirmed` (a real signed-in read landed — the wallet
  gates "N free shows left" on it) and a Keychain marker (service
  `com.salimhafid.UCBShows.ucb`, account `session-valid`,
  `AfterFirstUnlockThisDeviceOnly`, never iCloud Keychain) so launch starts
  in `.checking` and cached tickets render immediately.
  `completeSignIn() → RefreshOutcome` is handed straight to `tickets.adopt`
  so sign-in costs one navigation. `TicketStore`: `reserved: [Ticket]` +
  `studentID` in `tickets.json` (mirrored to iCloud; an empty remote copy
  is refused and the local wallet re-pushed). Carry-forward by order id keeps
  `showID/start/posterURL`, and keeps the old QR/title/venue when a partial
  page read comes back blank. Show ↔ ticket join from the tapped show
  (`pendingJoins`) or a unique title + venue-local-night match
  (`ReminderPlan.uniqueBooking`), backfilled when the feed lands. Foreground
  sync throttled to one per 5 minutes (`syncIfStale`). `reserve(show:)` also
  adopts an `alreadyClaimed` answer (reserved on the website) into the
  wallet. `release(_:) → ActionResult`: on a successful POST it re-syncs; if
  two reads fail it drops the ticket locally (a spent nonce must not linger).
  `Ticket.isReleasable(now:)` = nonce present and > 1 h before start (false
  when undated); `isPast` = 3 h after start; `Ticket.cleanVenue` /
  `Show.cleanVenueName` share one anchored, case-insensitive regex for the
  `NY – 14th St. ` / `LA - ` prefixes. `StudentReserveButton` sits between
  the heart and Get Tickets on UCB shows ("Reserve · Free").
- **Apple Wallet** (`WalletPass`, `AddToWalletButton`): a `.pkpass` is built
  and CMS-signed **on device** (`swift-certificates`, `@_spi(CMS) import
  X509`) for the Student ID (storeCard, `locations` = both UCB venues) or a
  reserved ticket (eventTicket, its venue, `relevantDate`). The QR payload is
  decoded from our rasterized SVG with Vision (CIDetector fallback). Signing
  identity = `PassSigning/pass_cert.pem` + `pass_key.pem` (git-ignored;
  `wwdr_g4.pem` committed); no certificate in the bundle → the button hides.
  **The signing key ships inside the binary** (and the synchronized root
  group copies everything under `ios/UCBShows/`, PassSigning/README.md
  included): an extractor could sign cosmetic passes under this pass type
  id — no payment/identity risk, rotate the certificate if that ever
  matters. `Venue` maps per SOURCE (14th Street, Franklin); an LA **Annex**
  ticket's pass geo-surfaces at Franklin because no verified Annex
  coordinates exist in the repo (don't invent them). Wallet is absent on
  iPad; the button also hides when the ticket has no QR. The app itself uses
  no location services.
- **QR rendering** (`QRRender`): UCB's inline SVG is rasterized once through
  an off-screen `WKWebView` snapshot (430 pt side) into an `NSCache` keyed by
  the SVG (16 entries / 96 MB), concurrent requests coalesced; the ticket
  screen shows the QR at maximum brightness while visible.
- **DEBUG UITEST launch-env hooks** (Support/UITestSupport.swift,
  Support/DebugFixtures.swift, detail view): `UITEST_TAB` (0 Shows /
  1 Tickets / 2 Classes), `UITEST_PUSH_SOURCE=<source id>`,
  `UITEST_TALENT=directory|person|<name>`, `UITEST_SCROLL_CAST=1`,
  `UITEST_CALENDAR_DIALOG=1`, `UITEST_SHARE=1`, `UITEST_SIDEBAR=1` (no-op on
  regular width — there is no drawer on iPad), **`UITEST_FAKE_TICKETS=1`**
  (or launch argument `-UITestFakeTickets`: seeds a signed-in account, a
  sample Student ID and a reserved ticket in memory, never persisted; a
  built pass is also dumped to Documents as `debug_pass.pkpass`),
  **`UITEST_RESTORING=1`** (holds the account in the launch-restore phase to
  capture the "Updating…" wallet state; combine with the fake tickets to put
  a cached wallet behind it).
- **Dependencies**: one SPM package, `apple/swift-certificates`
  (`upToNextMajor 1.0.0`; `Package.resolved` pins 1.19.4 with swift-asn1
  1.7.1 and swift-crypto 4.5.1). A clean clone resolves it on first build.
  `SWIFT_VERSION = 5.0`; the first Swift 6 strict-concurrency blockers are
  `DateUtils`' static `ISO8601DateFormatter`s, the harness's `var failures`,
  and the `Task.detached` captures in `WalletPass`/`PosterPipeline`.

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
  destination `upload` (or `export` for a local .ipa — nothing local is
  produced by default), `manageAppVersionAndBuildNumber` false (the build
  number is bumped by hand; Xcode must not rewrite it at upload).
- **Version rule**: a train closes once approved — 1.2, 1.3 and 1.4 are
  closed (builds 19 and 20 were uploaded into 1.3 and are stranded); new
  uploads must carry MARKETING_VERSION ≥ 1.5 (currently 1.5). The upload fails at
  the very END of a ~15 min export with "Invalid Pre-Release Train", so
  check the train before archiving, not after. Both settings appear twice in
  the pbxproj (Debug+Release) — sed with /g.
- `ITSAppUsesNonExemptEncryption = NO` is baked in — no compliance prompt.
- `CODE_SIGN_ENTITLEMENTS = UCBShows/UCBShows.entitlements` (aps-environment
  `development` in the file; iCloud container + CloudKit; KVS). The watcher
  writes alerts to both CloudKit environments, so development and App Store
  builds both receive them.
- Wallet passes need `PassSigning/pass_cert.pem` + `pass_key.pem` in the
  tree at build time (git-ignored) — see ios/UCBShows/PassSigning/README.md.
  **Provisioned 2026-09-07 on this Mac**: the key was generated locally and
  the certificate (Pass Type ID cert `W9X9BAT6PU` for
  `pass.com.salimhafid.UCBShows.studentid`, expires **2027-10-07**) was issued
  through the App Store Connect API with an Admin API key
  (`~/.appstoreconnect/private_keys/AuthKey_Z2D635L4F3.p8`, issuer
  `69a6de7b-5ff3-47e3-e053-5b8c7c11a4d1`) using `tools/asc_pass_cert.py`.
  Build 1.5 (25) is the first build that carries the PEMs. To renew: run the
  same script with a fresh CSR before the expiry; a certificate created from
  someone else's CSR is useless here (its key is not on this Mac — the
  keyless August certificate `9Q4BX69A2Y` still sits in the account and can
  be revoked).
- **"Failed to Use Accounts"** on upload = Xcode's ASC session expired →
  user signs in via Xcode ▸ Settings ▸ Accounts, then retry (no rebuild).
- App record creation is web-only, but everything the version page does —
  create the version, What's New, promotional text, App Review notes, build
  selection, Submit for Review — works through the ASC API with an Admin or
  App Manager key: `tools/asc_release.py` (see its docstring; a new version
  inherits the previous localization, screenshots and review contact, but
  not What's New / promo text). App Privacy answers and the age rating are
  still edited on the web. The live listing's Support and Marketing URL is
  `https://mabbles.org/improv/` (a landing page — the GitHub URL in
  metadata.md was never applied); the Privacy Policy URL is
  `https://github.com/salimhafid/improv/blob/main/PRIVACY.md`.
  Listing copy lives in ios/AppStore/metadata.md; screenshots in
  ios/screenshots/appstore{,-65,-ipad}/ (6.9" 1320×2868 native; 6.5"
  1284×2778 derived via sips resize+crop; iPad 13" 2064×2752). They predate
  the Tickets tab and the Classes redesign.
- `ios/project.yml` (XcodeGen) is the regeneration escape hatch; it mirrors
  the pbxproj's settings, the entitlements path, and the swift-certificates
  package — keep it in step when either changes.

## Simulator verification recipe

```bash
xcrun simctl boot <udid>            # list: xcrun simctl list devices available
# no onboarding to skip; seed the selection directly if you need a non-default one
xcrun simctl spawn <udid> defaults write com.salimhafid.UCBShows selectedTheaters -array "ucb_ny"
xcrun simctl status_bar <udid> override --time "9:41" --batteryState charged --batteryLevel 100
SIMCTL_CHILD_UITEST_PUSH_SOURCE=ucb_ny xcrun simctl launch <udid> com.salimhafid.UCBShows
SIMCTL_CHILD_UITEST_TAB=1 SIMCTL_CHILD_UITEST_FAKE_TICKETS=1 xcrun simctl launch <udid> com.salimhafid.UCBShows  # wallet without a UCB login
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
- iCloud KVS and CloudKit pushes need a signed-in iCloud account on the
  simulator; without one the app runs fine and `syncIssue` reads "Sign in to
  iCloud…".

## Watchlist — known live outages

- **Second City shows frozen 2026-08-12 → fixed on this branch.** PatronTicket
  stopped sending `custom.Event_City__c`; the `== "Chicago"` Toronto guard
  rejected every instance, `second_city` raised "parsed no showtimes from any
  show page" on every run, and the feed carried a frozen 541-show set
  (`stale: true, scraped_at: null`). The adapter now skips an instance only
  when the field is present and names another city, and reads the stage from
  `showAttributes.venue[].name`. **To confirm after merge**: the next
  scheduled run's log shows `second_city: scraped N`, and
  `sources[second_city].scraped_at` in `docs/shows.json` is no longer null.
- **ucbcomedy.com answers 202 to the Actions runner** (intermittently for
  `ucb_ny` shows since July — the source still succeeds on some runs — and on
  every recent run for the three talent pages, while the DCM endpoint
  alternates between success and a non-JSON body). Root cause unknown (a
  Cloudflare-style challenge is the working theory). This branch: the first
  202/non-JSON body per host is logged once at WARNING (read it in the scrape
  log), a 202 counts as a challenge for the fingerprint rotation, and the
  talent sweep backs off 6 h after a total failure instead of retrying every
  tick. Until it clears, `docs/talent.json` keeps carrying the 2026-08-31
  roster and `ucb_ny` runs on whatever ticks get through.

## Access & conventions

- **GitHub push**: user's fine-grained PAT, supplied in-conversation (not
  stored on disk; scratchpad copies get wiped — re-ask the user if needed).
  Remote `origin` = plain https; push with the token inline. Commits MUST
  use author email `1709833+salimhafid@users.noreply.github.com` (email
  privacy is on; real-email commits are rejected).
- The scrape bot commits every hour or so → **always `git pull --rebase`
  before pushing; on docs/*.json conflicts take the newer feed (usually
  `git checkout --theirs` during rebase of your local commit)**. The
  class-watch bot commits only to `class-watch-state`, never to main.
- **History**: `main` was force-pushed on **2026-08-08** (dropped ≈113 bot
  commits from 07-22 → 08-08) and on **2026-09-04** (every commit rewritten
  for a vendor-name scrub; `deploy.sh` purged). Author/committer dates
  survived, but **no commit hash quoted before 2026-09-04** (run logs, older
  notes, ASC build notes) resolves in today's history — use dates and
  messages, not hashes, when digging.
- Xcode holds the Apple ID session; simulators available include iPhone 17
  Pro Max (6.9" shots) and iPad Pro 13-inch (M5).
- Scraping stack: python3 via `.venv/bin/python` (3.9; CI is 3.12),
  curl_cffi with TLS impersonation rotating `chrome / chrome120 / safari`
  across retries (several sites block plain clients). `cryptography` is a
  requirement (watcher signing).
- Actions secrets: `CLOUDKIT_KEY_ID`, `CLOUDKIT_KEY_ID_PROD`,
  `CLOUDKIT_PRIVATE_KEY` (watcher). Nothing else is secret; feeds are public.
- **No AI co-author trailers on commits** (user decision 2026-07-22; no
  commit in today's history carries one — Salim is the sole human
  contributor).

## Money

$0/month for everything (public-repo Actions + raw CDN). The only recurring
cost anywhere is Apple's $99/yr developer program, which also covers
CloudKit, APNs, iCloud KVS and the Wallet pass type id.

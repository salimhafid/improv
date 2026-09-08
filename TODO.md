# TODO.md — open items, watchlist, and likely next steps

Companion to [CONTEXT.md](CONTEXT.md). Status as of 2026-09-07 (fixes merged
to main; app 1.5 build 25 submitted for review, WAITING_FOR_REVIEW).

## Release

- [x] **Ship 1.5** — done 2026-09-07 via `tools/asc_release.py`: version 1.5
      created, What's New + promo text set, App Review notes rewritten, build
      **25** (the first with Wallet pass signing; 24 hides Add to Wallet)
      attached, submitted (submission `bc15d605…`, WAITING_FOR_REVIEW).
      Anything new after that must bump CURRENT_PROJECT_VERSION (both
      configs) past 25.
- [ ] **Watch the 1.5 review**: it was submitted without a demo UCB student
      login (see below). If App Review asks for one under guideline 2.1,
      reply in the Resolution Center with credentials rather than
      resubmitting. Once approved, the train closes — 1.6 next.
- [x] Support / Privacy URLs confirmed 2026-09-07: the live Support and
      Marketing URL is `https://mabbles.org/improv/` (a working landing page,
      deliberately kept — not the GitHub URL metadata.md used to list);
      Privacy Policy URL is `https://github.com/salimhafid/improv/blob/main/PRIVACY.md`.
- [x] App Review notes on 1.5 now match `ios/AppStore/metadata.md` (optional
      UCB account, CloudKit pushes, iCloud sync); the old "no account or
      login" text is gone.
- [ ] App Privacy answers in ASC (web-only, no API): re-read against
      PRIVACY.md — nothing collected by us, CloudKit subscription for class
      alerts, iCloud KVS for settings/saved shows. Unchanged since 1.4 and
      not re-checked this round.
- [ ] A demo UCB student login for App Review (the reserve / QR / Wallet flow
      is invisible without one). 1.5's notes state the flow needs an enrolled
      UCB student account and that the rest of the app reviews without one.

## Watchlist (check occasionally; all fail-soft)

- [ ] **Second City shows** were frozen 2026-08-12 → 2026-09 (PatronTicket
      dropped `Event_City__c`; the Toronto guard rejected everything). Fixed
      on this branch; confirm on the first scheduled run after merge that
      `second_city.scraped_at` in `docs/shows.json` is no longer null and the
      count moves off 541. The stage now comes from `showAttributes.venue`
      — the blank-venue rate (68 % of the frozen carry) should drop; if it
      doesn't, the field moved again.
- [ ] **ucbcomedy.com 202s** to the Actions runner: all three talent pages fail
      every run (roster carried from 2026-08-31), DCM alternates 202 / non-JSON,
      `ucb_ny` shows succeed only on some ticks. This branch logs the first
      offending body per host once per run at WARNING (`ucb.common`) — read it
      in the scrape log to learn what Cloudflare is serving — and backs the
      talent sweep off 6 h after a total failure. Root cause and remedy
      (different fingerprint? request volume? egress IP?) still open.
- [ ] **A failing source is due every run** (its `scraped_at` stays null), and
      the cron is now hourly: a broken Second City costs ~91 requests/hour
      until fixed. Consider a failure back-off in `run_sources` like the
      talent sweep's.
- [ ] Annoyance meta enrichment (descriptions/images) is partial whenever
      ThunderTix 429s mid-run; self-heals daily. If chronically bad, add
      per-URL carry-over like the UCB detail cache. (180-day horizon ≈ 80
      productions/run — watch 429 frequency.)
- [ ] UCB shows pagination (`?_page=N`) stops when a page adds nothing new,
      capped at `_MAX_PAGES = 8` — no page-size assumption any more. If UCB's
      feed count ever snaps back to exactly one page (88/city today), WPGB
      stopped server-rendering history pages; if LA ever needs > 8 pages the
      cap truncates silently.
- [ ] Second City classes ride `/_next/data/<buildId>/find-a-class/chicago.json`;
      a Next.js build mid-scrape 404s once (fail-soft, carries). Chronic
      failure likely means the route or payload shape changed.
- [ ] Detail-enrichment: budget 400 fetches/run plus an 8-minute wall-clock
      deadline (bios: 150 + 5 minutes). Live first-time targets are ~247 UCB
      shows + ~70 Magnet URLs, so a backlog converges in one or two runs via
      `detail_done`; a source that starts hanging (not erroring) now costs at
      most the deadline.
- [ ] Playground depends on a hardcoded Google Calendar id (in
      sources/playground.py). If the theater regenerates it, the source
      raises and carries; re-extract the id from their show-calendar page
      (`calendar.google.com/calendar/embed?src=…` in the Canva HTML).
- [ ] GitHub Actions cron starvation: the scrape cron moved to hourly (`23 * *
      * *`) because a 3-hourly one was delivered 2–5×/day. If delivered
      cadence drops again, the same trick (more ticks, cheap no-ops) is the
      only lever short of a real scheduler. The bot's own commits keep the
      workflow from being auto-disabled at 60 days of repo inactivity.
- [ ] **Class-alert watcher on Actions** (`class-watch.yml`): a job that loops
      and re-dispatches itself ~24 h/day is a serverless cron, which GitHub's
      Actions usage policy lists as prohibited. Never enforced so far; if the
      workflow is ever disabled, alerts stop. A real host (or accepting a
      slower scheduled cadence) is the fallback plan. Related: ~144
      `class-watch-state` commits/day because `updated` is rewritten every
      scan (it doubles as the `--all-if-stale` stamp — a second "last scanned"
      stamp would let it commit only on id changes); a one-shot `ucb|all|both`
      dispatched while a chain is live runs concurrently and can double-alert.
- [ ] ASC screenshots predate the Second City / Logan Square / Playground
      additions, the Classes redesign (school folders) and the **Tickets** tab
      (no set has a wallet shot), and the iPad shot still shows the retired
      "All Theaters" row and "Change City" footer. A
      refresh would show the current app (recipe in CONTEXT.md; wallet via
      `UITEST_FAKE_TICKETS=1`).
- [x] **Production push receipt on a physical device**: the owner-only test
      wrote to production at `2026-09-08T20:32:32Z` (run `34275363613`), and
      the user confirmed receipt on their phone. Temporary test objects were
      removed; the record cleanup retry succeeded in run `34275715138`.
- [ ] **UCB production subscription recovery (2026-09-08)**: record writes,
      exact queries, and owner-only phone push receipt succeeded, but native
      registration failed with a missing `notif_title_loc_arg_0` production
      schema field. Earlier REST probes used incorrect notification-title wire
      names and did not check the returned settings, so query-shape acceptance
      after two schema promotions did not establish native compatibility.
      The corrected probe reproduced the exact failure; the title-bearing
      templates are now deployed. Run `34278590602` verified all three shapes'
      full title/body configuration in both environments at 21:05 UTC.
      Remaining: confirm the app's saved UCB subscriptions reconcile on
      foreground. Evidence and
      diagnostic modes are in CONTEXT.md's production UCB failure runbook.

## Open items left by the 2026-09-07 fix pass

Skipped or deferred by the fixing agents, with the reason — none are bugs
that break the build.

- [ ] **Wallet signing key ships in the binary** (`PassSigning/`): an extractor
      could sign cosmetic passes under our pass type id. Accepted for now;
      rotate the certificate if it ever matters. Also pin `swift-certificates`
      tighter than `upToNextMajor 1.0.0` — `@_spi(CMS)` is not covered by
      semver.
- [ ] **LA Annex coordinates**: `Venue.forSource` maps every `ucb_la` ticket to
      Franklin, so an Annex ticket's Wallet pass geo-surfaces a block away.
      Needs verified coordinates for a per-`venueLabel` map — none exist in
      the repo, do not invent them.
- [ ] **Swift 6 readiness**: `SWIFT_VERSION = 5.0`. Known blockers under
      strict concurrency: `DateUtils`' static `ISO8601DateFormatter`s, the
      harness's `var failures`, `Task.detached` captures of
      `UIImage`/`Ticket`/`SigningIdentity` in `WalletPass.pass(for:)` and the
      `NSString` key in `PosterPipeline`. Also the dead project-level
      `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (target is 18.6) and the
      `#available(iOS 18.0, *)` else-branches in `Modifiers.swift`.
- [ ] **Localisation**: the app is English-only; `Localizable.strings` sits at
      the bundle root and holds only the `CA_TITLE`/`CA_BODY` passthroughs
      that CloudKit pushes need. The first real `en.lproj` localisation must
      migrate that file or pushes lose their titles.
- [ ] iCloud KVS **last-writer-wins ping-pong** for `tickets.json`: device B
      signing out publishes an empty wallet, device A refuses it and re-pushes,
      B re-adopts A's tickets into its hidden cache and arms reminders. Same
      iCloud user, so harmless today; a real fix needs per-device tombstones.
      Related: `pushFile` is not held back until the initial KVS sync, so a
      heart in the first seconds after a fresh install can be overwritten by
      the cloud copy — needs a merge in `GoingStore.reloadFromCloud`.
- [ ] **Mixed-city day sections** in the I'm-Going list take Today/Tomorrow
      from the first show's zone (`DaySection.group`); keying sections on
      city+day would change the grouping — product decision.
- [ ] `SourceInfo.stale`/`scraped_at` are decoded but ignored by the app, so a
      carried source (`ucb_ny`, Second City) renders as fully available. The
      data is there if the sidebar should hint "last updated N days ago".
- [ ] `ShowsStore.sections` memo key does not include the moving 6-hour grace
      cutoff, so between 00:00 and 06:00 a show crossing the line waits for
      the next key change to drop out. `ClassItem.hasKeyword` tolerates `+s`
      plurals but not `+es`. `SearchText.normalized` does not apply the
      `nameKey` Latin-letter fold (typing "soren" won't find "Søren").
- [ ] `QRCodeView` keeps the previous image if a new SVG fails to render;
      `UCBSignInView` shows no message when a detected sign-in turns out
      `.signedOut` (the sheet just stays up on the login form).
- [ ] Arlo class data: `Categories[0]` / `AdvertisedOffers[0]` are taken
      arbitrarily and the real description lives on the eventtemplate (one
      extra request per template) — product/API call.
- [ ] `run_tests.sh` writes `~/Library/Preferences/improv_logic_tests.plist`
      and creates `~/Library/Application Support/UCBShows/` (no `UserDefaults`
      suite / cache-dir injection point yet; tests reset state explicitly so
      runs stay order-independent).
- [ ] `class-watch.yml` `mode: test` tests development only (`--test` is
      dev-only; production needs `--test-prod` from a shell).
- [ ] Non-UCB `comedy_types` are now genre-only (Crowdwork allow-list, Second
      City rating/policy tags dropped, BCC rooms → venue): watch the filter
      chips after the first live run for anything that disappeared and
      shouldn't have.

## Nice-to-haves (discussed, not committed)

- [x] ~~UCB online classes~~ — DONE: scraped as `ucb_online` (Arlo LOC_Online,
      16 offerings), alertable in Class Alerts, and shown as a "UCB Online"
      folder in the Classes tab whenever a UCB campus is selected (pseudo-city
      `Online`, Eastern time). WGIS `/onlineclasses` (~7 open workshops) is
      still unscoped — same question.
- [x] ~~Second City stage/venue~~ — DONE on this branch: stage from
      `showAttributes.venue[].name`, slug heuristic as fallback. Verify live.
- [x] ~~Brooklyn CC polish~~ — DONE on this branch: Squarespace categories
      (rooms) map to `venue`/`venues`; class start dates parse out of product
      titles when the title carries a day.
- [ ] Arlo satellite locations (Austin, Pittsburgh, Edinburgh) if the app ever
      expands beyond NY/LA/Chicago.
- [ ] WGIS class enrichment (0% descriptions/images — needs per-workshop
      detail-page fetches) and show prices (cost.formatted is in the API;
      shows have no price field in the feed model today).
- [ ] iO Fest passes appear as "shows" (they're ticket bundles); Annoyance
      "CLASS:"-titled ThunderTix entries duplicate Crowdwork classes —
      both could use tagging/dedupe.
- [ ] Cast/talent for non-UCB theaters (no structured data found so far;
      Second City's patronticket blob has no lineup info). UCB `cast_members`
      may also name *teams* (`/people/<team-slug>/`) that never resolve in the
      directory.
- [ ] Hosted OG interstitial pages so *pasted* links get custom previews —
      **explicitly skipped by user** (needs a GitHub org for generic Pages);
      revisit only if asked.
- [ ] Tonight home-screen widget — built once (build ~1), removed by user
      request when cutting bandwidth. The code is in git history, but note
      that `main` was rewritten on 2026-09-04, so search by message/date
      (`git log --all -- 'ios/UCBWidget/*'`), not by old hashes.
- [ ] Talent directory: the PAGES list in sources/ucb_talent.py is the
      extension point if UCB adds rosters (e.g. touring companies).
- [ ] Watcher payload: `count`/`classIDs` are written but never read by the
      app (only `pushTitle`/`pushBody` are). Either use them (deep-link to
      the class) or drop them.

## Docs debt

- [x] ~~Root README.md describes the Cloud Host era~~ — DONE 2026-08-08.
- [x] ~~Collapse ShowsService / ClassesService / TalentService~~ — DONE
      2026-08-13 (`FeedService<Payload>`).
- [x] ~~UCBapp.md predates the raw-CDN move~~ — refreshed 2026-09-07 along
      with CONTEXT/README/ios README/PRIVACY/metadata.
- [ ] `ios/UCBShows/PassSigning/README.md` is copied into the app bundle by
      the synchronized root group (harmless; an `explicitFolders` exception
      would keep it out — but the PEM lookup must keep working).
- [ ] Keep `ios/project.yml` in step with the pbxproj whenever a build
      setting, entitlement or package changes (it was two trains stale).

## Session hygiene reminders (for the next Claude)

- Re-ask the user for the GitHub PAT when pushing (never stored on disk).
- Always `git pull --rebase` before pushing (the scrape bot commits hourly);
  keep the newer docs/*.json on conflicts.
- Rate-limit empathy: ThunderTix ≤3 concurrent; don't loop full-scrape tests
  back-to-back against it — and don't hammer ucbcomedy.com while it is
  already answering 202.
- After any app-code change that ships: bump CURRENT_PROJECT_VERSION (both
  configs), archive, upload, commit — the full runbook is in CONTEXT.md.
- Run `./run_tests.sh` (Python + Swift harness) before committing; CI only
  runs the Python half.

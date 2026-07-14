# Playbook: how Improv was built

A reusable recipe distilled from building the Improv iOS app (scraper → static
feed → native SwiftUI client → App Store), including the dead ends. Steal from
this for the next app.

## The shape

```
Python scrapers (one adapter per source)
        │  every 3h, GitHub Actions cron
        ▼
Static JSON feeds committed to docs/   ←  the repo itself is the database
        │  GitHub Pages + Fastly CDN (free, ETags automatic)
        ▼
SwiftUI app (offline-first, no accounts, no server of its own)
```

This shape fits any app whose data is **public, small (≤ a few MB), and
changes on a schedule rather than per-user**: event listings, schedules,
menus, rankings, prices. If you need per-user state on a server, auth, or
sub-minute freshness, you need a real backend — otherwise you probably don't.

## Backend / scraping

- **One adapter per source** (`sources/*.py`), each returning normalized dicts
  with the same shape. The aggregator tags `source`/`org`/`city` defensively so
  a lazy adapter can't produce untagged rows.
- **Browser impersonation from day one**: `curl_cffi` with `impersonate=
  "chrome"`. Comedy-theater sites sit behind Cloudflare; plain requests get
  blocked. This mattered more than any other scraping decision — it even
  worked from GitHub Actions' datacenter IPs, which is what made $0 hosting
  possible. Verify that assumption with a probe (below) before betting on it.
- **Per-source cadence + last-good carry-over**: each source has a scrape
  interval (busy source: 3h; others: 24h). A run only re-scrapes sources that
  are *due*; everything else carries forward from the previous payload, and a
  failed scrape carries stale data instead of wiping the source. This makes
  runs cheap, polite, and failure-tolerant.
- **The previous payload lives wherever the output lives** (`storage.py` has
  interchangeable backends: local dir / GCS). When output = the repo's
  `docs/`, checkout gives you last run's state for free — cadence works in
  stateless CI with zero extra infrastructure.
- **Detail-page budget**: enriching each item with a second fetch is
  quadratic-ish trouble; cap detail fetches per run and cache results by URL
  in the payload itself (`detail_done`).
- **Never publish an empty feed**: the publisher exits nonzero only if *every*
  source failed; partial failure publishes last-good data for the failures.

## Hosting: the $0 endgame

We started on Cloud Run (+ GCS + Scheduler) and migrated off. Lessons:

1. **Cloud Run was already ~free for compute** — the actual bill was 40 GB of
   accumulated `cloud-run-source-deploy` container images (~$4/mo). If you use
   Cloud Run with source deploys, set an Artifact Registry **cleanup policy on
   day one** (keep last 3, delete >30 days).
2. **GCP requires a billing account even for free-tier usage.** No card, no
   Cloud Run. That constraint, not cost, forced the better architecture.
3. **GitHub Actions (public repo) + GitHub Pages is genuinely $0**: unlimited
   Actions minutes, ~100 GB/mo Pages bandwidth over Fastly's CDN, automatic
   ETag/304 handling. The workflow scrapes, commits changed JSON to `docs/`,
   Pages serves it.
4. **Test runner-IP reachability with a probe mode** before trusting CI
   scraping: a `workflow_dispatch` input that scrapes from scratch into a
   throwaway dir (no previous payload → everything due) without committing.
   Watch the per-source log lines, not just the exit code — a "successful" run
   can be 100% cadence carry-over that scraped nothing.
5. **Serve from a domain you own** (Pages custom domain). The app points at
   `salimhafid.com/improv/...`, so hosting can move again without an app
   update.
6. Caveats to remember: scheduled workflows can lag minutes-to-an-hour at busy
   times, and GitHub disables crons after 60 days of repo inactivity — the
   bot's own feed commits keep it alive.

## iOS app

**Architecture** (works, keep):
- One-way data flow: `Service` (fetch + decode + on-disk last-good cache) →
  `@MainActor @Observable` store (filter/group/expose) → views. No view model
  layer beyond that.
- **Defensive Codable**: custom `init(from:)` where every field is
  `decodeIfPresent` with a default. Scraped data *will* have nulls and missing
  keys; one brittle field would kill the whole feed.
- **Offline-first**: cache the last good payload in Application Support (not
  Caches — survives storage pressure); show it instantly on launch with an
  "offline" banner, refresh in the background.
- **HTTP caching done right end-to-end**: server (or Pages) sends
  `ETag` + `max-age`; the app uses the default protocol cache policy (do NOT
  set `reloadIgnoringLocalCacheData`) so unchanged feeds cost a 0-byte 304.
- **Timezone rule for multi-city event data**: feed times are timezone-naive
  venue-local; parse, day-bucket, and label ("Today") each item in *its own
  city's* timezone. Never anchor to one city or the device zone. Keep one
  cached formatter per (format, zone).
- **Stable IDs across sources**: prefix every item id with its source id —
  different ticketing systems reuse numeric ids.

**Design** (the "Apple-clean for free" kit): stock components only, semantic
colors, system materials, SF Symbols, one accent color, full Dynamic Type,
`ContentUnavailableView` for every empty/error state, skeleton (`.redacted`)
first load, deterministic gradient covers (hash the title → hue) instead of
broken images, `.navigationTransition(.zoom)` card→detail. Dark mode and iPad
mostly fall out of doing this; on iPad, swap the drawer for a persistent
sidebar column at regular width.

**Project mechanics**:
- Xcode's file-system-synchronized groups mean new files need no pbxproj
  edits; the pbxproj stays tiny and hand-editable (we added and later removed
  a widget target purely by text edit).
- Keep a `project.yml` (XcodeGen) in sync as a regeneration escape hatch.
- Generated Info.plist: settings like `INFOPLIST_KEY_CFBundleDisplayName`,
  `INFOPLIST_KEY_NSCalendarsWriteOnlyAccessUsageDescription`, and
  `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` (set that last one on day
  one; it kills the export-compliance question on every upload).
- **DEBUG-only launch-environment hooks** (`UITEST_TAB`, `UITEST_PUSH_SOURCE`,
  `UITEST_SIDEBAR`) that jump straight to a given screen. They cost ~60 lines
  and make deterministic screenshots/verification trivial forever.

## App Store pipeline

What automates cleanly from the CLI (no fastlane needed):

```bash
xcodebuild -scheme App -destination 'generic/platform=iOS' \
  -archivePath App.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath App.xcarchive -exportPath Out \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
# ExportOptions: method app-store-connect; destination export → .ipa,
# destination upload → straight to App Store Connect using Xcode's session.
```

What cannot be automated: **creating the app record** (App Store Connect web
UI only), category/copyright fields, the privacy questionnaire, and pressing
Submit. Write all listing copy into `ios/AppStore/metadata.md` first (with
character limits: name 30, subtitle 30, promo 170, keywords 100) so the human
part is pure paste.

**Screenshots via simctl** (no XCUITest needed):
```bash
xcrun simctl boot <device>
xcrun simctl spawn <device> defaults write <bundle> hasCompletedSetup -bool YES  # skip onboarding
xcrun simctl status_bar <device> override --time "9:41" --batteryState charged --batteryLevel 100
SIMCTL_CHILD_UITEST_TAB=2 xcrun simctl launch <device> <bundle>   # env → screen
xcrun simctl io <device> screenshot out.png
xcrun simctl ui <device> appearance dark                          # dark variants
```
- Required sizes (2026): iPhone 6.9" = 1320×2868 (iPhone Pro Max sim), iPhone
  6.5" = 1284×2778 (derive from 6.9" via `sips -z 2789 1284` then center-crop
  `-c 2778 1284` — aspect delta is 0.4%, invisible), iPad 13" = 2064×2752
  (iPad Pro 13 sim) if the app targets iPad.
- After booting a fresh simulator, **wait ~30s before capturing** or a system
  notification banner will photobomb a shot (it got us once).
- Review every screenshot with your own eyes before uploading — one of ours
  exposed a raw scraper string ("NY - 14TH ST. ") that rows had cleaned but
  the detail page hadn't.

**Privacy**: apps like this collect nothing → App Privacy = "Data Not
Collected"; calendar access write-only (`requestWriteOnlyAccessToEvents`);
privacy policy is one static HTML page served next to the feeds.

## Ops hygiene (the boring saves)

- `git init` before touching anything; commit a pristine baseline first so
  every change is diffable. `.gitignore` the venv, caches, and any token files
  *before* the first commit.
- GitHub pushes fail with "email privacy restrictions" if commits use a real
  email — configure `<id>+<user>@users.noreply.github.com` up front.
- Verify claims against reality at each stage: curl the deployed URL, read the
  CI log lines, check the 304 actually returns 0 bytes, look at the pixels.
  Every "done" in this project was backed by one of those checks, and two
  "successes" (the first CI run, the first iPad screenshot) were only caught
  as hollow by looking.

## Reuse checklist

1. Repo + baseline commit + .gitignore. Public if you want free CI/hosting.
2. Scraper adapters + normalizer + cadence/carry-over + local-dir storage.
3. `publish_static.py` + Actions cron + Pages from `docs/` + custom domain.
4. Probe-mode dispatch → confirm per-source "scraped N" lines from a runner.
5. SwiftUI app: defensive models, offline-first services, @Observable stores,
   venue-local dates, stock-component design, UITEST hooks.
6. Info.plist keys incl. `ITSAppUsesNonExemptEncryption` from day one.
7. `metadata.md` with all listing copy; privacy page next to the feeds.
8. Archive/export/upload via xcodebuild; human creates the app record and
   pastes; simctl screenshots (6.9", derived 6.5", iPad 13", dark).
9. Budget check: whatever platform you're on, find the thing that silently
   accumulates (container images, old builds, logs) and cap it on day one.

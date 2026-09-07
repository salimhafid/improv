# Playbook: how Improv was built

A reusable recipe distilled from building the Improv iOS app (scraper → static
feed → native SwiftUI client → App Store), including the dead ends. Steal from
this for the next app. Refreshed 2026-09-07 against the code.

## The shape

```
Python scrapers (one adapter per source)
        │  GitHub Actions cron (hourly ticks; each source has its own cadence)
        ▼
Static JSON feeds committed to docs/   ←  the repo itself is the database
        │  raw.githubusercontent.com CDN (free, ETags automatic)
        ▼
SwiftUI app (offline-first, no server of its own; optional third-party
             sign-in lives inside a web view; Apple's CloudKit/iCloud for
             push alerts and cross-device settings)
```

This shape fits any app whose data is **public, small (≤ a few MB), and
changes on a schedule rather than per-user**: event listings, schedules,
menus, rankings, prices. If you need per-user state on a server, auth, or
sub-minute freshness, you need a real backend — otherwise you probably don't.
Per-user state that only needs to follow the user across *their own* devices
fits in iCloud key-value storage; "something happened" pushes fit a CloudKit
public database written from CI (see "Push without a server").

## Backend / scraping

- **One adapter per source** (`sources/*.py`), each returning normalized dicts
  with the same shape. The aggregator tags `source`/`org`/`city` defensively so
  a lazy adapter can't produce untagged rows.
- **Browser impersonation from day one**: `curl_cffi` with TLS impersonation,
  and rotate fingerprints across retries (`chrome → chrome120 → safari`) —
  Cloudflare rejects individual fingerprints with a 403, so a 403 must NOT
  short-circuit the retry. Comedy-theater sites sit behind Cloudflare; plain
  requests get blocked. This mattered more than any other scraping decision —
  it even worked from GitHub Actions' datacenter IPs, which is what made $0
  hosting possible. Verify that assumption with a probe (below) before betting
  on it, and log the first bad response body per host once so you can see
  what the challenge actually looks like when it starts.
- **Per-source cadence + last-good carry-over**: each source has a scrape
  interval (busy source: 3h; others: 24h). A run only re-scrapes sources that
  are *due*; everything else carries forward from the previous payload, and a
  failed scrape carries stale data instead of wiping the source. This makes
  runs cheap, polite, and failure-tolerant. Treat a 200 that parses to zero
  items as a failure too (markup changes look exactly like that). Give a
  *failing* source a back-off as well — otherwise it is due on every tick.
- **The previous payload lives wherever the output lives** (`storage.py` has
  one backend: a local directory, `LOCAL_STORE_DIR`). When output = the repo's
  `docs/`, checkout gives you last run's state for free — cadence works in
  stateless CI with zero extra infrastructure. (An object-storage backend
  existed in the hosted-container era and was deleted with it.)
- **Detail-page budget**: enriching each item with a second fetch is
  quadratic-ish trouble; cap detail fetches per run by count AND wall-clock
  (a host that hangs instead of erroring blows the job timeout otherwise),
  and cache results by URL in the payload itself (`detail_done`). Only a
  successful fetch sets the flag, so a transient failure is retried.
- **Never publish an empty feed**: the publisher exits nonzero only if no
  source is healthy (`ok` and `count > 0` — a legitimately empty source must
  not vouch for an empty feed) or a write failed; partial failure publishes
  last-good data for the failures.
- **Venue-local "today"**: CI runners are UTC; filter "upcoming" in each
  venue's own timezone or the evening runs drop tonight's shows.

## Hosting: the $0 endgame

We started on a managed container host (+ object storage + a scheduler) and
migrated off. Lessons:

1. **Compute itself was already ~free** — the actual bill was 40 GB of
   accumulated source-deploy container images (~$4/mo). If your host builds an
   image per deploy, set an image-registry **cleanup policy on day one**
   (keep last 3, delete >30 days).
2. **The host required a billing account even for free-tier usage.** No card,
   no deploy. That constraint, not cost, forced the better architecture.
3. **GitHub Actions (public repo) + raw.githubusercontent.com is genuinely
   $0**: unlimited Actions minutes and a CDN with automatic ETag/304 handling.
   The workflow scrapes and commits changed JSON to `docs/`; the app reads
   `https://raw.githubusercontent.com/<user>/<repo>/main/docs/<file>`. No
   GitHub Pages, no custom domain — the raw URL is hardcoded in the app
   (`FeedService.liveFeed`), which has been fine because the repo is the
   stable thing. (An earlier salimhafid.com hosting step was retired.)
4. **Test runner-IP reachability with a probe mode** before trusting CI
   scraping: a `workflow_dispatch` input that scrapes from scratch into a
   throwaway dir (no previous payload → everything due) without committing.
   Watch the per-source log lines, not just the exit code — a "successful" run
   can be 100% cadence carry-over that scraped nothing.
5. **Scheduled workflows are starved on quiet repos**: a 3-hourly cron was
   delivered 2–5 times a day. Schedule more often than you need (hourly ticks
   that are cheap no-ops when nothing is due) rather than trusting the
   scheduler. GitHub also disables crons after 60 days of repo inactivity —
   the bot's own feed commits keep it alive.
6. **Push without a server**: a CloudKit *public* database can be written from
   CI with a server-to-server key (ECDSA-signed requests, three repo secrets);
   devices register `CKQuerySubscription`s for the records they care about and
   Apple's APNs does the fan-out. To get a real 10-minute cadence out of
   Actions we run a self-perpetuating job (loop, sleep, dispatch your
   successor) restarted by throttled cron "kickers" — it works, but it is a
   serverless cron on Actions and sits close to GitHub's usage policy. Know
   that going in. Send alerts *before* saving state and park anything a
   backend didn't accept for retry (at-least-once), and never treat an empty
   scan as "everything was removed".

## iOS app

**Architecture** (works, keep):
- One-way data flow: one generic `FeedService<Payload>` (fetch + decode +
  on-disk last-good cache) → `@MainActor @Observable` store (filter/group/
  expose) → views. No view model layer beyond that.
- **Defensive Codable**: custom `init(from:)` where every field is
  `decodeIfPresent` with a default (and `try?` per scalar, lossy arrays for
  nested lists). Scraped data *will* have nulls and missing keys; one brittle
  field would kill the whole feed. Apply the same to your own persisted
  preferences — a blob written by an older build must decode with defaults,
  not reset the user.
- **Offline-first**: cache the last good payload in Application Support (not
  Caches — survives storage pressure); show it instantly on launch with an
  "offline" banner, refresh in the background; move an undecodable cache file
  aside instead of deleting it.
- **HTTP caching done right end-to-end**: the CDN sends `ETag`; the app uses
  the default protocol cache policy (do NOT set `reloadIgnoringLocalCacheData`)
  so unchanged feeds cost a 0-byte 304; pull-to-refresh uses
  `.reloadRevalidatingCacheData`.
- **Timezone rule for multi-city event data**: feed times are timezone-naive
  venue-local; parse, day-bucket, and label ("Today") each item in *its own
  city's* timezone. Never anchor to one city or the device zone. Keep one
  cached formatter per (format, zone).
- **Stable IDs across sources**: prefix every item id with its source id —
  different ticketing systems reuse numeric ids.
- **Cross-device settings for free**: `NSUbiquitousKeyValueStore` mirrors a
  handful of defaults keys and small JSON files. Adopt the cloud copy on a
  fresh install, push local changes (last writer wins), never delete cloud
  state, and hold pushes until the initial sync has landed.
- **Third-party login without an API**: when a site sits behind Cloudflare
  Turnstile and has no API, one persistent `WKWebView` over a named
  `WKWebsiteDataStore` can be both the login surface's cookie jar and the API
  client (injected `fetch()` runs with the real cookies + TLS fingerprint).
  Serialize operations behind a lock, bound every navigation with a timeout,
  detect "signed in" by a positive dashboard marker (not "no login form"),
  and never wipe cached state on an inconclusive read.
- **Apple Wallet passes on device**: `swift-certificates` can CMS-sign a
  `.pkpass` manifest without a server. The trade-off is that the signing key
  ships inside the binary — fine for cosmetic passes, rotate if it matters.

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
  a widget target purely by text edit). Everything under the folder is
  bundled — keep secrets out of it (git-ignore, and know what ships).
- Keep a `project.yml` (XcodeGen) in sync as a regeneration escape hatch —
  including packages, `CODE_SIGN_ENTITLEMENTS`, and version numbers, or it
  regenerates a project that doesn't build. Ours drifted for two release
  trains before anyone noticed.
- Generated Info.plist: settings like `INFOPLIST_KEY_CFBundleDisplayName`,
  `INFOPLIST_KEY_NSCalendarsWriteOnlyAccessUsageDescription`, and
  `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` (set that last one on day
  one; it kills the export-compliance question on every upload).
- **DEBUG-only launch-environment hooks** (`UITEST_TAB`, `UITEST_PUSH_SOURCE`,
  `UITEST_SIDEBAR`, `UITEST_FAKE_TICKETS`, …) that jump straight to a given
  screen or seed fake account state. They cost ~60 lines and make
  deterministic screenshots/verification trivial forever.
- A Swift logic harness that compiles the Foundation-only sources with
  `swiftc` into a command-line binary (no Xcode test target) runs in seconds
  and keeps models/stores honest; pin its clock so fixtures never age out.

## App Store pipeline

What automates cleanly from the CLI (no fastlane needed):

```bash
xcodebuild -scheme App -destination 'generic/platform=iOS' \
  -archivePath App.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath App.xcarchive -exportPath Out \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
# ExportOptions: method app-store-connect; destination export → .ipa,
# destination upload → straight to App Store Connect using Xcode's session;
# manageAppVersionAndBuildNumber=false if you bump build numbers by hand.
```

What cannot be automated: **creating the app record** (App Store Connect web
UI only), category/copyright fields, the privacy questionnaire, and pressing
Submit. Write all listing copy into `ios/AppStore/metadata.md` first (with
character limits: name 30, subtitle 30, promo 170, keywords 100) so the human
part is pure paste. A version train closes on approval — bump
MARKETING_VERSION before the next upload or the export fails at the very end.

**Screenshots via simctl** (no XCUITest needed):
```bash
xcrun simctl boot <device>
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

**Privacy**: an app like this collects nothing on servers of yours; calendar
access write-only (`requestWriteOnlyAccessToEvents`). The privacy policy is a
Markdown file in the repo (`PRIVACY.md`) and its GitHub blob URL is the
policy URL in App Store Connect — no HTML page needed. The moment you add a
third-party sign-in, iCloud sync, or CloudKit pushes, rewrite the policy and
the App Review notes the same day; ours lagged the code by weeks.

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
- If you ever rewrite history (we did twice), write it down: every hash in old
  notes stops resolving, and the next person will burn an hour on it.
- Keep the docs honest per release: a "complete as-built reference" that
  describes the app two trains ago is worse than none.

## Reuse checklist

1. Repo + baseline commit + .gitignore. Public if you want free CI/CDN.
2. Scraper adapters + normalizer + cadence/carry-over + local-dir storage.
3. `publish_static.py` + Actions cron (hourly ticks) → `docs/` on the raw CDN.
4. Probe-mode dispatch → confirm per-source "scraped N" lines from a runner.
5. SwiftUI app: defensive models, offline-first generic feed service,
   @Observable stores, venue-local dates, stock-component design, UITEST hooks,
   `swiftc` logic harness.
6. Info.plist keys incl. `ITSAppUsesNonExemptEncryption` from day one;
   `project.yml` mirroring the pbxproj.
7. `metadata.md` with all listing copy; `PRIVACY.md` in the repo as the policy URL.
8. Archive/export/upload via xcodebuild; human creates the app record and
   pastes; simctl screenshots (6.9", derived 6.5", iPad 13", dark).
9. Budget check: whatever platform you're on, find the thing that silently
   accumulates (container images, old builds, logs, state-branch commits) and
   cap it on day one.

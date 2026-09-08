# Improv — iOS app

A native **SwiftUI** app for browsing upcoming improv/comedy shows, classes,
and the UCB talent directory across theaters in New York, Los Angeles, and
Chicago (plus UCB's online classes). It reads the repo's scheduled
multi-source feeds (`docs/shows.json`, `docs/classes.json`, `docs/talent.json`
via GitHub's raw CDN) and presents them with a first-party, Apple-clean
aesthetic. UCB students can optionally sign in to reserve free student
tickets and carry the QR codes (and an Apple Wallet pass) in the app.

<p>
  <img src="UCBShows/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="96" alt="App icon">
</p>

**Theaters**: UCB New York, Brooklyn Comedy Collective, Magnet Theater,
WGIS New York (NYC); UCB Los Angeles, WGIS Los Angeles (LA); The Annoyance,
iO Theater, The Second City, Logan Square Improv, The Playground Theater
(Chicago); UCB Online (classes only, shown with either UCB campus).

## Run it

Requires **Xcode 16+** (iOS 18.6 deployment target, Swift 5 language mode).

```bash
open ios/UCBShows.xcodeproj
```

Pick an iPhone or iPad simulator (or your device) and press **Run** (⌘R).

One Swift package dependency: [`apple/swift-certificates`](https://github.com/apple/swift-certificates)
(with its `swift-asn1` / `swift-crypto` dependencies, pinned in
`Package.resolved`), used only to CMS-sign Apple Wallet passes on device.
Xcode resolves it on the first build. The Add-to-Wallet button appears only
when a pass-signing certificate is present in `UCBShows/PassSigning/`
(git-ignored; see the README there) — without it the app builds and runs
normally. A `project.yml` is included if you ever need to regenerate the
project with XcodeGen; it mirrors the pbxproj's settings, entitlements and
package.

Class alerts and iCloud sync need the app's entitlements (CloudKit container
`iCloud.com.salimhafid.UCBShows`, push, key-value store) and a signed-in
iCloud account on the device or simulator; everything else works without one.

> The screenshots in `screenshots/` are from an earlier design iteration
> (source-toggle Setup, two tabs) and predate the sidebar / Tickets tab
> redesign. `screenshots/appstore{,-65,-ipad}/` hold the App Store sets.

## What it does

- **Theater scoping** — no onboarding: the app opens on UCB New York, and a left
  sidebar (hamburger, or swipe right) lists every theater grouped by city. Pick
  any mix; the city follows from the selection. Unavailable sources are greyed
  out; live counts per theater match the visible tab.
- **Shows tab** — a date-sectioned chronological feed for the selected scope
  (Today / Tomorrow / weekday headers, pinned), with an inline search bar.
  Past days' shows drop out of the list (a show that started late last night
  stays for six hours).
- **Tickets tab** — the standby **UCB Student ID** and any **reserved student
  tickets** on top (each opening a full-screen, max-brightness QR for the
  door, cached so it works offline), and the shows you've hearted ("I'm
  Going") below, grouped by date. Hearted shows persist across launches (even
  after they leave the feed) and schedule a local reminder an hour before
  showtime (if you allow notifications). A show you also hold a ticket to gets
  exactly one reminder — the ticket's, which opens the QR.
- **UCB sign-in, reserve, release** — optional. Signing in happens on UCB's own
  `/my-account/` page inside a web view; the session (cookies) stays in an
  on-device WebKit data store and a Keychain marker remembers that a session
  exists. On a UCB show, a **Reserve · Free** button between the heart and Get
  Tickets claims a student ticket in one tap; tickets can be released from
  their detail page until an hour before showtime.
- **Apple Wallet** — Add to Wallet for the Student ID (surfaces near either UCB
  theater) and for each reserved ticket (surfaces at its venue around
  showtime). Passes are built and signed on device; see `UCBShows/PassSigning/`.
- **Classes tab** — browsed city-wide rather than theater-by-theater: every
  school in the selected theaters' cities gets a collapsible card (the picked
  theaters first; a "UCB Online" folder rides along with either UCB campus),
  grouped by subject inside, with separate **Improv Core** and **Sketch Core**
  groups for UCB (Improv 101–401, Sketch 101–301) and BCC (Improv 1–4,
  Sketch 1–2). Each
  class has a native detail page (description, instructor, schedule, price)
  with **Register** opening the registration page in an in-app Safari sheet.
  UCB links select the exact course session. Searching auto-expands every
  matching folder.
- **Class alerts** — the bell in the Classes toolbar: a master switch, per-
  category toggles for UCB New York / Los Angeles / Online and BCC, and simple
  on/off rows for every other school. Newly enabling a categorized school
  selects everything except Improv Core and Sketch Core; existing UCB picks
  are retained. Alerts are CloudKit push notifications
  (`CKQuerySubscription`s the device registers for itself) written by the
  repo's watcher workflow when a school posts new classes; tapping one opens
  the Classes tab.
- **Talent** — UCB show pages list the cast as chips; a matched performer opens
  a bio page (headshot, city, scraped bio, their upcoming shows), an unmatched
  name opens the directory pre-searched. The directory filters All / New York /
  Los Angeles and supports pull-to-refresh.
- **Filters** (Shows tab) — venue, comedy type (multi-select), livestream, free,
  and a date window (This weekend = Fri–Sun). Filters persist across launches,
  the toolbar icon shows an active-count badge, and selections are
  auto-cleared if their venue/type stops being available in the current scope.
- **Show detail** — stretchy poster header, metadata chips, blurb, cast section,
  Share (rich link preview), **Add to Calendar** (first use asks Apple vs
  Google; Apple = write-only EventKit, Google = the calendar template URL,
  remembered afterwards), and a pinned bar with the heart, the student
  Reserve button on UCB shows, and **Get Tickets** (in-app Safari).
- **iCloud sync** — selected theaters, filters, class-alert preferences, the
  calendar choice, the I'm-Going list and the ticket wallet are mirrored
  through iCloud key-value storage, so they follow you across your devices
  and reinstalls.
- **Pull to refresh** (Shows, Classes, Talent) — re-fetches the published feed.
  It never triggers a scrape; scraping happens on the backend's schedule, and
  refresh surfaces whatever the last run stored.
- **Offline** — the last successful payloads are cached to disk, so the app
  opens instantly and shows saved data (with a banner) when the network is
  unavailable.
- **iPad** — on regular width the theater sidebar becomes a persistent leading
  column instead of a drawer. (Apple Wallet is not available on iPad.)

## Design

Materials-first, content-led, stock components only — large titles, SF Symbols,
system materials, a single coral accent, full Dynamic Type, and light/dark for
free via semantic colors. Missing posters render a deterministic typographic
`GeneratedCover` rather than a broken image. Card→detail uses the zoom
navigation transition. All date logic is venue-local: each show is parsed,
day-bucketed, and labeled in its own city's timezone, so "Today" flips at the
venue's midnight in every city.

## Architecture

```
UCBShows/
  UCBShowsApp.swift          @main; CloudSync.bootstrap() first, URLCache sizing,
                             notification delegate, APNs registration delegate,
                             builds + injects the eight stores, wires tickets/
                             account/alerts, deep-links, 5-min ticket sync on foreground
  UCBShows.entitlements      aps-environment, iCloud container + CloudKit, KVS
  Localizable.strings        CA_TITLE / CA_BODY passthroughs for CloudKit pushes
  Models/
    Show.swift               Codable model (defensive) + derived display values
    Class.swift              class/workshop model, subject classification
    Source.swift             City (incl. Online pseudo-city) + theater catalog + feed source info
    Filters.swift            value-type filter state (shows)
    Talent.swift             talent payload + person (nameKey normalization)
    Ticket.swift             a held UCB ticket (Student ID or reserved), release/expiry rules
    Venue.swift              UCB venue coordinates for Wallet pass locations
  Services/
    FeedService.swift        generic fetch + on-disk last-good cache (all feeds)
    ShowsStore.swift         @MainActor @Observable source of truth for shows; filters; sections
    ClassesStore.swift       same for classes; school folders + subject groups
    TalentStore.swift        talent directory + name/slug index; phase
    GoingStore.swift         saved "I'm Going" shows + pre-show reminders
    TicketStore.swift        Student ID + reserved tickets (tickets.json), joins, reminders
    UCBAccountStore.swift    UCB sign-in phase/name/eligibility + Keychain marker
    UCBSession.swift         the UCB "session engine": one WKWebView as cookie jar + API client
    WalletPass.swift         builds + CMS-signs .pkpass on device (swift-certificates)
    QRRender.swift           SVG QR → cached UIImage via off-screen WKWebView
    ClassAlertsStore.swift   class-alert prefs + CloudKit subscription reconcile
    CloudSync.swift          iCloud key-value mirror of settings + going.json/tickets.json
    NotificationAuth.swift   one place to ask for notification permission
    NotificationRouter.swift UNUserNotificationCenter delegate; routes taps to tickets/shows/classes
    ReminderPlan.swift       shared reminder math (lead time, one-per-show joins)
    CalendarService.swift    Apple (write-only EventKit) / Google (template URL) Add to Calendar
    Keychain.swift           minimal Keychain wrapper (session marker, this device only)
    AppState.swift           selected theaters/tab (+ inferred city), deep-link targets
  Support/
    DateUtils.swift          per-timezone parsing/formatting + day grouping
    AppSupport.swift         Application Support dir; moves undecodable files aside
    SearchText.swift         search normalization shared by shows/classes
    UITestSupport.swift      DEBUG launch-env hooks (UITEST_*)
    DebugFixtures.swift      DEBUG fake wallet (UITEST_FAKE_TICKETS / UITEST_RESTORING)
  DesignSystem/Theme.swift   accent, radii, per-type tints & symbols
  PassSigning/               wwdr_g4.pem (committed) + pass_cert.pem/pass_key.pem (git-ignored); README
  Resources/ucb_skull.png    Wallet pass artwork
  Views/                     RootView (Shows / Tickets / Classes), ShowsFeedView,
                             ShowDetailView, ClassesView, ClassDetailView, ClassAlertsView,
                             TicketWalletView, TicketDetailView, UCBSignInView,
                             StudentReserveButton, AddToWalletButton, TalentViews
  Views/Components/          TheaterSidebar/TheaterListPanel, TheaterIcon, ShowRow, ClassRow,
                             ShowSectionsList, PosterImage/GeneratedCover, FilterSheet, Chips,
                             ShareShow, Modifiers, Supporting (offline banner, in-app Safari)
```

Data flows one way: services fetch/decode → stores hold, filter, and date-group
→ SwiftUI views render. Stores are `@MainActor @Observable`; cache reads happen
off the main actor. The UCB session engine is the one place that talks to a
third party on the user's behalf, and it does so inside a web view so
requests carry the real cookies and TLS fingerprint (UCB sits behind
Cloudflare Turnstile).

The project uses Xcode's *file-system synchronized* group, so new files added
under `UCBShows/` are picked up automatically — no `.pbxproj` edits needed.
(Everything under the folder is bundled, PassSigning/README.md included.)

## Data source

The `FeedService` factories (`.shows` / `.classes` / `.talent`) point at the
static feeds in this repo's `docs/` folder, served via raw.githubusercontent.com
(committed by the scheduled scrape workflow). To point at a different backend,
change the `liveFeed` base URL in `Services/FeedService.swift`.

## Tests

`../run_tests.sh` compiles the Foundation-only sources (models, stores'
logic, `DateUtils`, `SearchText`, `ReminderPlan`, `Ticket`, `Venue`…) with
`tests/ios/LogicTests.swift` into a command-line binary and runs its asserts —
no Xcode test target, no simulator. UIKit/WebKit/CloudKit-dependent files are
not covered there; they are verified by the app build.

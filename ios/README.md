# Improv — iOS app

A native **SwiftUI** app for browsing upcoming improv/comedy shows and classes
across multiple theaters in New York, Los Angeles, and Chicago. It reads the
repo's scheduled multi-source feeds (`docs/shows.json`, `docs/classes.json`,
`docs/talent.json` via GitHub's raw CDN) and presents them with a first-party,
Apple-clean aesthetic.

<p>
  <img src="UCBShows/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="96" alt="App icon">
</p>

**Theaters**: UCB New York, Brooklyn Comedy Collective, Magnet Theater,
WGIS New York (NYC); UCB Los Angeles, WGIS Los Angeles (LA); The Annoyance,
iO Theater, The Second City, Logan Square Improv, The Playground Theater (Chicago).

## Run it

Requires **Xcode 16+** (built against Xcode 26.6, iOS 18.6 deployment target).

```bash
open ios/UCBShows.xcodeproj
```

Pick an iPhone or iPad simulator (or your device) and press **Run** (⌘R).

No third-party dependencies, no package resolution — it builds as-is. A
`project.yml` is included if you ever need to regenerate the project with
XcodeGen.

> The screenshots in `screenshots/` are from an earlier design iteration
> (source-toggle Setup, two tabs) and predate the sidebar/I'm Going redesign.

## What it does

- **City + theater scoping** — pick your home city on first launch (change it
  anytime); a left sidebar (hamburger, or swipe right) lists that city's
  theaters plus an **All Theaters** whole-city feed. Unavailable sources are
  greyed out; live counts per theater match the visible tab.
- **Shows tab** — a date-sectioned chronological feed for the selected scope
  (Today / Tomorrow / weekday headers, pinned), with an inline search bar.
- **I'm Going tab** — tap the heart on a show's page to save it. Saved shows
  persist across launches (even after they leave the feed), group by date,
  badge the tab with a count, and schedule a local reminder ~3 hours before
  showtime (if you allow notifications).
- **Classes tab** — classes & workshops for the same scope, grouped by
  level/track, with level and open-seats filters. Each class has a native
  detail page (description, instructor, schedule, price) with **Register**
  opening the registration page in an in-app Safari sheet.
- **Filters** — venue, comedy type (multi-select), livestream, free, and a date
  window (This weekend = Fri–Sun). Filters persist across launches, the toolbar
  icon shows an active-count badge, and selections are auto-cleared if their
  venue/type stops being available in the current scope.
- **Show detail** — stretchy poster header, metadata chips, blurb, cast section,
  Share, **Add to Calendar** (write-only EventKit access), and a pinned bar with
  the I'm Going heart and **Get Tickets** (in-app Safari).
- **Pull to refresh** (Shows and Classes) — re-reads the backend store. It never
  triggers a scrape; scraping happens on the backend's schedule, and refresh
  surfaces whatever the last run stored.
- **Offline** — the last successful payloads are cached to disk, so the app
  opens instantly and shows saved data (with a banner) when the network is
  unavailable.
- **iPad** — on regular width the theater sidebar becomes a persistent leading
  column instead of a drawer.

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
  UCBShowsApp.swift          @main; injects the stores, sets the tint
  Models/
    Show.swift               Codable model (defensive) + derived display values
    Class.swift              class/workshop model, same conventions
    Source.swift             City (timezone) + theater catalog + feed source info
    Filters.swift            value-type filter state (shows + classes)
  Services/
    ShowsService.swift       fetch + on-disk last-good cache (shows.json)
    ClassesService.swift     same for classes.json
    ShowsStore.swift         @MainActor @Observable source of truth for shows
    ClassesStore.swift       same for classes
    GoingStore.swift         saved "I'm Going" shows + pre-show reminders
    CalendarService.swift    write-only EventKit "Add to Calendar"
    AppState.swift           selected city/theater/tab; drives all scoping
  Support/DateUtils.swift    per-timezone parsing/formatting + day grouping
  DesignSystem/Theme.swift   accent, radii, per-type tints & symbols
  Views/                     RootView, ShowsFeedView, GoingView, ClassesView,
                             ShowDetailView, ClassDetailView, SetupView
  Views/Components/          TheaterSidebar/TheaterListPanel, ShowRow, ClassRow,
                             PosterImage/GeneratedCover, FilterSheet, Chips, …
```

Data flows one way: services fetch/decode → stores hold, filter, and date-group
→ SwiftUI views render. Stores are `@MainActor @Observable`; cache reads happen
off the main actor.

The project uses Xcode's *file-system synchronized* group, so new files added
under `UCBShows/` are picked up automatically — no `.pbxproj` edits needed.

## Data source

`ShowsService.feedURL` / `ClassesService.feedURL` / `TalentService.feedURL`
point at the static feeds in this repo's `docs/` folder, served via
raw.githubusercontent.com (committed by the scheduled scrape workflow). To
point at a different backend (e.g. a local `python app.py`), change those
constants.

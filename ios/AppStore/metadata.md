# App Store listing — Improv

Everything needed for the App Store Connect listing. Character limits noted;
all fields below are within them.

## App name (30 chars max)
```
Improv: Comedy Shows & Classes
```
(30 chars. If taken, fallbacks: "Improv Tonight" / "Improv — Live Comedy Guide")

## Subtitle (30 chars max)
```
Live comedy in NYC, LA & CHI
```

## Category
Primary: Entertainment. Secondary: Lifestyle (optional).

## Promotional text (170 chars max, editable without review)
```
Tonight's improv, sketch, and standup across New York, Los Angeles, and
Chicago — with showtime reminders and every theater in one feed.
```

## Description (4000 chars max)
```
One app for the improv scene. Improv gathers upcoming shows and classes from
the theaters you love — UCB New York, Brooklyn Comedy Collective, Magnet
Theater, and WGIS in New York; UCB and WGIS in Los Angeles; The Annoyance and
iO in Chicago — and puts them in a single, fast, native feed.

SHOWS, ORGANIZED BY NIGHT
Browse a clean, date-sectioned feed for one theater or your whole city. Every
show has a page with the poster, lineup, description, and a Get Tickets button
that opens the theater's own box office.

I'M GOING
Tap the heart on any show and it lands in your I'm Going list — grouped by
date, badged with a count, and saved even if the listing later leaves the
feed. Allow notifications and you'll get a reminder a few hours before
showtime. One tap adds the show to your calendar.

FIND EXACTLY YOUR KIND OF FUNNY
Filter by comedy type (improv, sketch, standup, character), venue, free shows,
livestreams, or a date window like this weekend. Search works across titles
and descriptions. Filters persist and never strand you — anything that stops
being available clears itself.

CLASSES TOO
Every theater's classes and workshops, grouped by level, with instructor,
schedule, price, and open-seat filtering. Register in a couple of taps.

BUILT LIKE APPLE BUILT IT
Native SwiftUI, full Dynamic Type, light and dark mode, offline support (your
last feed is always available), iPad layout with a persistent sidebar. No
accounts, no ads, no tracking — see our one-paragraph privacy policy.

Improv is an independent guide. Shows and classes are listed with links to
each theater's own ticketing; all sales happen on the theater's site.
```

## Keywords (100 chars max, comma-separated, no spaces needed)
```
improv,comedy,ucb,standup,sketch,shows,tonight,magnet,annoyance,theater,tickets,classes,brooklyn
```
(97 chars)

## URLs
- Support URL: `https://salimhafid.github.io/improv/`
- Privacy Policy URL: `https://salimhafid.github.io/improv/privacy.html`
- Marketing URL: (optional, leave blank)

## App Privacy questionnaire
- Data collection: **Data Not Collected** (no accounts, analytics, ads, or
  third-party SDKs; feed requests are anonymous content downloads).

## Age rating questionnaire
- All "None" except: **Profanity or Crude Humor → Infrequent/Mild** (comedy
  show titles/descriptions occasionally contain strong language). Result: 12+.

## App Review notes (paste into "Notes" in the review section)
```
Improv is a listings guide for live comedy theaters. All show/class data is
publicly available information (titles, dates, venues, descriptions) served
from our own backend, which aggregates the theaters' public calendars. The
app sells nothing: "Get Tickets" / "Register" open each theater's own website
in an in-app Safari view, and all purchases happen there. No account or login
is required anywhere in the app. Calendar access is write-only and only used
when the user taps "Add to Calendar". Notifications are optional local
reminders for shows the user saves.
```

## Screenshots (required before submission)
- 6.7" iPhone (1290×2796): Shows feed, show detail, I'm Going, Classes,
  sidebar/All Theaters. 13" iPad (2064×2752) if iPad screenshots are enabled.
- Capture from the simulator once CoreSimulator is fixed (reboot/update);
  the repo's UITEST_* launch variables can drive each screen deterministically.

## Build
- Bundle ID: com.salimhafid.UCBShows · Version 1.0 · Build 1
- Signed IPA exported at scratchpad Export/UCBShows.ipa (re-exportable any time)

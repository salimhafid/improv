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
(28 chars)

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
Theater, and WGIS in New York; UCB and WGIS in Los Angeles; The Annoyance,
iO, The Second City, Logan Square Improv, and The Playground in Chicago — and puts them in a single, fast, native feed.

SHOWS, ORGANIZED BY NIGHT
Browse a clean, date-sectioned feed for one theater or your whole city. Every
show has a page with the poster, lineup, description, and a Get Tickets button
that opens the theater's own box office.

TICKETS & I'M GOING
Tap the heart on any show and it lands in your I'm Going list — grouped by
date, and saved even if the listing later leaves the feed. Allow notifications
and you'll get a reminder an hour before showtime. One tap adds the show to
your calendar. UCB students can sign in to their UCB account to reserve free
student tickets in one tap and keep the QR codes in the app — and in Apple
Wallet.

FIND EXACTLY YOUR KIND OF FUNNY
Filter by comedy type (improv, sketch, standup, character), venue, free shows,
livestreams, or a date window like this weekend. Search works across titles
and descriptions. Filters persist and never strand you — anything that stops
being available clears itself.

CLASSES TOO
Every school in your city — not just the theater you picked — with its classes
and workshops in a collapsible card, grouped by subject inside, each with
instructor, schedule, and price. Register in a couple of taps, and turn on
class alerts to hear when a school posts new classes.

BUILT LIKE APPLE BUILT IT
Native SwiftUI, full Dynamic Type, light and dark mode, offline support (your
last feed is always available), iPad layout with a persistent sidebar, iCloud
sync of your settings and saved shows. No ads, no tracking, no account of
ours — see our short privacy policy.

Improv is an independent guide. Shows and classes are listed with links to
each theater's own ticketing; all sales happen on the theater's site.
```

## Keywords (100 chars max, comma-separated, no spaces needed)
```
improv,comedy,ucb,standup,sketch,shows,tonight,magnet,annoyance,theater,tickets,classes,brooklyn
```
(96 chars)

## URLs
- Support URL: `https://github.com/salimhafid/improv`
- Privacy Policy URL: `https://github.com/salimhafid/improv/blob/main/PRIVACY.md`
- Marketing URL: (optional, leave blank)

## App Privacy questionnaire
- We collect nothing on any server of ours: no analytics, ads, or tracking
  SDKs; feed requests are anonymous content downloads. Data the app handles
  stays on the device or in the user's own iCloud (settings, saved shows,
  ticket QR codes) or goes to the third party the user chose to talk to (UCB
  when signing in / reserving; Google when using Google Calendar). Class
  alerts register a CloudKit subscription recording the user's school /
  category picks so Apple can deliver the push. Answer the questionnaire from
  PRIVACY.md — "Data Not Collected" is the honest answer for data *we*
  collect, but re-read Apple's current definitions before submitting.

## Age rating questionnaire
- All "None" except: **Profanity or Crude Humor → Infrequent/Mild** (comedy
  show titles/descriptions occasionally contain strong language). Result: 12+.

## App Review notes (paste into "Notes" in the review section)
```
Improv is a listings guide for live comedy theaters. All show/class data is
publicly available information (titles, dates, venues, descriptions) that our
GitHub Actions workflow scrapes from the theaters' public calendars and
publishes as static JSON files; the app downloads those files. The app sells
nothing: "Get Tickets" / "Register" open each theater's own website in an
in-app Safari view, and all purchases happen there.

No account is required to use the app. An OPTIONAL sign-in to an existing
UCB (Upright Citizens Brigade) account, on UCB's own web page inside the app,
lets UCB students reserve free student tickets and see their ticket QR codes
(Tickets tab, and optionally Apple Wallet). Reservations are free; no payment
is taken anywhere in the app. Demo UCB student login for review:
  email:    <DEMO_UCB_STUDENT_EMAIL — fill in before submitting>
  password: <DEMO_UCB_STUDENT_PASSWORD>
(The Tickets tab and the show page's "Reserve · Free" button show the flow.)

Calendar access is write-only and only used when the user taps "Add to
Calendar". Notifications: local reminders for saved shows/tickets, plus
optional "new classes posted" alerts delivered as CloudKit push notifications
the user opts into (Classes tab → bell). The app uses no location services;
a Wallet pass carries the theater's location so Wallet can surface it nearby.
```

## Screenshots
Three sets are checked in under `ios/screenshots/`:
- `appstore/` — 6.9" iPhone (1320×2868): 01 shows feed, 02 show detail,
  03 sidebar, 04 classes, 05 shows dark.
- `appstore-65/` — 6.5" iPhone (1284×2778), derived from the 6.9" set with
  `sips` (resize + center-crop), same five shots.
- `appstore-ipad/` — 13" iPad (2064×2752): 01 shows, 02 detail, 03 classes,
  04 shows dark.

They predate the Tickets tab, the school-folder Classes redesign and the
Chicago additions; refresh with the simulator recipe in CONTEXT.md
(`UITEST_TAB`, `UITEST_PUSH_SOURCE`, `UITEST_FAKE_TICKETS=1` for the wallet)
before the next listing update.

## Build
- Bundle ID: com.salimhafid.UCBShows · Version 1.4 · Build 23 (pbxproj
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, both configurations).
- `xcodebuild -exportArchive` with `ios/ExportOptions.plist` uploads straight
  to App Store Connect (`destination = upload`); no local IPA is produced
  unless `destination` is changed to `export`. Full runbook in CONTEXT.md.

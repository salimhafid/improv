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
Live value (carried over onto 1.6):
```
One app for every improv scene
```
Longer alternative, unused so far:
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
instructor, schedule, and price. Register in a couple of taps, and unlock
class alerts (a one-time in-app purchase) to hear when a school posts new
classes.

BUILT LIKE APPLE BUILT IT
Native SwiftUI, full Dynamic Type, light and dark mode, offline support (your
last feed is always available), iPad layout with a persistent sidebar, iCloud
sync of your settings and saved shows. No ads, no tracking, no account of
ours — see our short privacy policy.

Improv is an independent guide. Shows and classes are listed with links to
each theater's own ticketing; all sales happen on the theater's site.
```
The "(a one-time in-app purchase)" wording is new for 1.8 and has to be set
on the 1.8 version (a new version inherits 1.7's description): App Review
guideline 2.3.2 asks a description to say when a feature it promotes needs
an extra purchase.

## Keywords (100 chars max, comma-separated, no spaces needed)
```
improv,comedy,ucb,standup,sketch,shows,tonight,magnet,annoyance,theater,tickets,classes,brooklyn
```
(96 chars)

## URLs (as live in App Store Connect, confirmed 2026-09-07)
- Support URL: `https://mabbles.org/improv/` (landing page)
- Marketing URL: `https://mabbles.org/improv/`
- Privacy Policy URL: `https://github.com/salimhafid/improv/blob/main/PRIVACY.md`

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
- 1.8's Class Alerts purchase doesn't change that: Apple processes the
  payment, and the app checks the entitlement and original download version
  on device through StoreKit and sends them nowhere (no "Purchases" data
  collected by us).

## In-app purchase — Class Alerts (from 1.8)

| Field | Value |
|---|---|
| Product ID | `com.salimhafid.UCBShows.classalerts` |
| Type | Non-consumable |
| Reference name | Class Alerts |
| Display name (en-US, 30 max) | Class Alerts |
| Description (en-US, 45 max) | Alerts when schools post new classes |
| Price | USD 9.99 (base territory USA; other territories follow Apple's equalization) |
| Availability | Every territory, plus new ones |
| Family Sharing | Off (Apple doesn't allow turning it off once on) |
| Review screenshot | The paywall: Classes tab → bell |

IAP review note (set by the tool):
```
Unlocks Class Alerts: push notifications when improv schools post new classes. Open the Classes tab, tap the bell. Existing users who installed before version 1.8 keep the feature free.
```
Created and kept in step by `tools/asc_iap.py create --screenshot <png>`
(`status` is read-only; `--dry-run` prints the writes). The app's first IAP
has to be submitted together with an app version: add it on the 1.8 version
page before Submit for Review. Needs the Paid Applications Agreement active
(App Store Connect → Business). The local Xcode copy is `ios/UCBShows.storekit`.

## Age rating questionnaire
- All "None" except: **Profanity or Crude Humor → Infrequent/Mild** (comedy
  show titles/descriptions occasionally contain strong language). Result: 12+.

## What's New — 1.6 (as submitted 2026-09-08)

Exact submitted text: [whatsnew-1.6.txt](whatsnew-1.6.txt).

UCB and BCC classes now have separate Improv Core and Sketch Core categories.
Newly enabled class alerts include every category except core, with core
courses available to opt into. BCC now supports category-specific alerts.
UCB registration links open the exact class session instead of the overall
catalog.

## What's New — 1.5 (as submitted 2026-09-07)
```
• Apple Wallet: add your UCB student ID and reserved show tickets to Wallet, with the QR code and venue on the pass.
• UCB Online classes now appear as their own folder whenever a UCB theater is selected.
• Class alerts are more reliable: your school and category picks persist across updates and sync between devices.
• Tickets: reservations appear right away after signing in, "already reserved" pulls the ticket in, and another device signing out no longer empties this one.
• Listings: Second City, Playground, WGIS, and Magnet shows are complete and accurate again, with cleaner descriptions.
• Performers directory gains retry, offline, and pull-to-refresh states.
• Many smaller fixes, from saved-show reminders to the venue filter and iPad layout.
```
(1.4 shipped with "Bug fixes".)

## App Review notes

### 1.8 — draft (not yet submitted)

Replaces the 1.5 base text below, whose "The app sells nothing" and "no
payment is taken anywhere in the app" stop being true with the Class Alerts
purchase. Save it as `review-notes-1.8.txt` when submitting and set it with
`tools/asc_release.py review <versionId> review-notes-1.8.txt`. **Before
submitting, `docs/app-config.json` must say `"testflight_free": false`**:
review installs run in the sandbox, so `true` would unlock alerts for the
reviewer and hide the purchase.

```
Improv is a listings guide for live comedy theaters. All show/class data is
publicly available information (titles, dates, venues, descriptions) that our
GitHub Actions workflow scrapes from the theaters' public calendars and
publishes as static JSON files; the app downloads those files. "Get Tickets" /
"Register" open each theater's own website in an in-app Safari view, and all
ticket and class purchases happen there.

IN-APP PURCHASE (new in 1.8): "new classes posted" alerts are now unlocked by
a one-time, non-consumable in-app purchase, "Class Alerts" (USD 9.99, product
ID com.salimhafid.UCBShows.classalerts). It is the app's only purchase;
everything else stays free. To find it: open the Classes tab and tap the bell
in the toolbar. The Class Alerts sheet opens with the "Unlock for <price>" and
"Restore Purchase" buttons at the top; the alert switches below stay visible
but disabled until the purchase completes. After buying, Class Alerts switch
on and the app asks for notification permission.

People who installed Improv before version 1.8 keep Class Alerts free: the
app reads AppTransaction.originalAppVersion and compares it with the first
paid build, in the production App Store environment only. Sandbox installs,
App Review's included, are never treated as earlier users, so the purchase
always appears during review.

No account is required to use the app, and every core feature (shows,
classes, saving, reminders, filters, search) works without signing in. An
OPTIONAL sign-in to an existing UCB (Upright Citizens Brigade) account, on
UCB's own web page inside the app, lets current UCB students reserve free
student tickets and see their ticket QR codes (Tickets tab, and optionally
Apple Wallet). Reservations are free; UCB takes no payment through the app.
The reservation flow is only available to enrolled UCB students, so it
requires a real UCB student account; the rest of the app is fully reviewable
without one.

Calendar access is write-only and only used when the user taps "Add to
Calendar". Notifications: local reminders for saved shows/tickets, plus the
optional "new classes posted" alerts (the purchase above), delivered as
CloudKit push notifications the user opts into (Classes tab -> bell). The app
uses no location services; a Wallet pass carries the theater's location so
Wallet can surface it nearby.
```

### 1.5 base (used through 1.6)

Version 1.6's exact submitted notes are in
[review-notes-1.6.txt](review-notes-1.6.txt). They retain the following 1.5
explanation and append instructions for the new category and alert controls.
The inherited review contact was verified complete; `demoAccountRequired`
remains false.

```
Improv is a listings guide for live comedy theaters. All show/class data is
publicly available information (titles, dates, venues, descriptions) that our
GitHub Actions workflow scrapes from the theaters' public calendars and
publishes as static JSON files; the app downloads those files. The app sells
nothing: "Get Tickets" / "Register" open each theater's own website in an
in-app Safari view, and all purchases happen there.

No account is required to use the app, and every core feature (shows,
classes, saving, reminders, filters, search) works without signing in. An
OPTIONAL sign-in to an existing UCB (Upright Citizens Brigade) account, on
UCB's own web page inside the app, lets current UCB students reserve free
student tickets and see their ticket QR codes (Tickets tab, and optionally
Apple Wallet). Reservations are free; no payment is taken anywhere in the
app. The reservation flow is only available to enrolled UCB students, so it
requires a real UCB student account; the rest of the app is fully reviewable
without one.

Calendar access is write-only and only used when the user taps "Add to
Calendar". Notifications: local reminders for saved shows/tickets, plus
optional "new classes posted" alerts delivered as CloudKit push notifications
the user opts into (Classes tab -> bell). The app uses no location services;
a Wallet pass carries the theater's location so Wallet can surface it nearby.
```
If a demo UCB student login becomes available, add it to the notes as
`Demo UCB student login: email … / password …` and set "Sign-in required"
in the review section (the API field is `demoAccountRequired`).

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
- Bundle ID: com.salimhafid.UCBShows · Version **1.8** · Build **28** — the
  project's current setting, not yet uploaded; the first build with the Class
  Alerts purchase (builds before 28 are the grandfathering cutoff).
- Bundle ID: com.salimhafid.UCBShows · Version **1.6** · Build **26**.
  Uploaded 2026-09-08 and verified VALID with no non-exempt encryption.
  Submitted at **2026-09-08T21:48:26.855Z**; version and submission both
  verified **WAITING_FOR_REVIEW**, with automatic release after approval.
  Version ID: `a0beecd9-9a84-4748-a4c6-32e38dfcc2e0`.
  Build ID: `da247794-2bbd-4ca6-92f5-c3fbf7dd4574`.
  Review submission: `ed477148-5b78-43d4-a963-ada1ab0d0a95`.
  Description, keywords, URLs, review contact and screenshots were inherited
  from approved 1.5. All inherited screenshot assets verified COMPLETE
  (6 APP_IPHONE_67, 4 APP_IPHONE_65, 3 APP_IPAD_PRO_3GEN_129).
- Bundle ID: com.salimhafid.UCBShows · Version 1.5 · Build 25, uploaded and
  submitted for review 2026-09-07 — the first build with Wallet pass signing
  provisioned; build 24 (same day) lacks it (pbxproj `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION`, both configurations).
- The version page is driven from the CLI: `tools/asc_release.py` (create
  version, What's New, review notes, attach build, submit).
- `xcodebuild -exportArchive` with `ios/ExportOptions.plist` uploads straight
  to App Store Connect (`destination = upload`); no local IPA is produced
  unless `destination` is changed to `export`. Full runbook in CONTEXT.md.

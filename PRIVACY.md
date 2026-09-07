# Privacy Policy — Improv

*Last updated: September 7, 2026*

Improv is an app for browsing upcoming improv and comedy shows and classes.
It is designed to collect no personal data. We run no servers and receive
nothing from your device.

## Data we collect

None. The app has no accounts of its own, no analytics, no advertising, and
no third-party analytics or advertising SDKs. We do not collect, store, sell,
or share any personal information. (The only third-party code in the app is
Apple's open-source `swift-certificates` library, used to sign Apple Wallet
passes on your device; it makes no network requests.)

## How the app works

The app downloads publicly available show, class, and performer listings from
static files hosted on GitHub. Like any web request, the hosting provider
briefly processes your device's IP address to deliver that content; we never
see it, and it is not linked to you. Show posters and performer headshots are
loaded directly from each theater's own website, so those hosts see the same
kind of request.

## On-device data

Your selected theaters, filters, class-alert preferences, calendar choice,
saved ("I'm Going") shows, and any UCB tickets you hold in the app (see below)
are stored on your device. So that they follow you between your own devices,
they are also mirrored through your personal iCloud account — that goes to
Apple under Apple's privacy policy, never to any server we run. Turning on
class alerts additionally registers a notification subscription in the app's
iCloud container, recording which schools and categories you picked, so Apple
can deliver the alert as a push notification. If you use "Add to Calendar"
with Apple Calendar, the app writes the event using write-only access — it
can never read your calendar; if you choose Google Calendar, the show's title,
time, venue, and description are handed to Google in the link that opens
Google Calendar. Reminder notifications for saved shows and tickets are
scheduled locally on your device.

## Optional UCB account

If you are a UCB student you can sign in to your existing ucbcomedy.com
account from inside the app to reserve free student tickets. You sign in on
UCB's own web page, shown in a web view; the app never sees or stores your
password. The resulting session cookies are held in an on-device WebKit data
store, and a small Keychain marker records that a session exists — neither is
synced to iCloud Keychain. While signed in, the app reads your UCB account
page to show your name, student eligibility, free-ticket allowance, your
Student ID QR code, and your reserved tickets, and it sends reservation and
release requests to ucbcomedy.com on your behalf when you tap Reserve or
Release. All of this happens between your device and UCB under UCB's privacy
policy. Your Student ID and ticket QR codes are cached on the device so they
work offline at the door, and — like your saved shows — are mirrored to your
own iCloud account. Signing out clears the session and the cached tickets.

If you add a ticket to Apple Wallet, the pass is created and signed on your
device and handed to Wallet; nothing is uploaded. The pass carries the
theater's location so Wallet can show it on your lock screen when you are
nearby — the app itself never accesses your location.

## Ticket purchases

Tapping "Get Tickets" or "Register" opens the theater's own website in an
in-app browser. Purchases happen entirely on the theater's site under its
privacy policy. Student reservations through the app are free and are made
directly with UCB, as described above.

## Contact

Questions? Email [hi@salimhafid.com](mailto:hi@salimhafid.com).

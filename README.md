# Improv — live comedy shows, classes & talent

**Improv** is a free iOS app that aggregates upcoming live-comedy shows,
classes, and UCB talent across **New York, Los Angeles, and Chicago** —
eleven theaters (plus UCB's online classes), one feed, zero backend cost.

- App Store: **Improv** (bundle `com.salimhafid.UCBShows`)
- Feeds (this repo, served from GitHub's raw CDN):
  [shows.json](https://raw.githubusercontent.com/salimhafid/improv/main/docs/shows.json) ·
  [classes.json](https://raw.githubusercontent.com/salimhafid/improv/main/docs/classes.json) ·
  [talent.json](https://raw.githubusercontent.com/salimhafid/improv/main/docs/talent.json)

## How it works

```
GitHub Actions cron (hourly; each source has its own 3h/24h cadence)
  → publish_static.py  (LOCAL_STORE_DIR=docs — the checkout IS the state)
      scraper.py   → docs/shows.json    (11 sources, per-performance)
      classes.py   → docs/classes.json  (11 sources, incl. UCB Online)
      talent.py    → docs/talent.json   (UCB directory, ~1.7k people)
  → commits changed feeds

Class alerts: a second Actions workflow (watcher.py) scans the class sources
every ~10 minutes and writes CloudKit records; devices that opted in receive
them as push notifications. State lives on the `class-watch-state` branch.

iOS app (ios/) fetches the raw-CDN JSON (URLSession's default cache policy →
ETag/304 revalidation).
```

There is no server: the scrapers run on Actions, and the repo's `docs/`
folder is both the previous-run state (per-source cadences and enrichment
caches carry across runs) and the published content. The only services
beyond the repo are Apple's — CloudKit for class alerts and iCloud
key-value storage that mirrors each user's own settings.

### Theaters

| City | Sources |
|---|---|
| New York | UCB, Brooklyn Comedy Collective, Magnet Theater, WGIS |
| Los Angeles | UCB, WGIS |
| Chicago | The Second City, iO Theater, The Annoyance, Logan Square Improv, The Playground Theater |
| Online | UCB Online (classes only) |

### Resilience model

Every source is fail-soft: a scrape failure — or a suspicious 200-OK page
that parses to zero items — keeps that source's last-good data (flagged
stale) instead of wiping it from the feed. Detail/bio enrichment is budgeted
per run (request count and wall-clock) and converges across runs; transient
fetch failures are retried rather than cached as empty. `publish_static.py`
refuses to overwrite a feed with emptiness when no source contributed items.
Upcoming-ness is judged in each venue's own timezone, so evening scrape runs
don't drop that night's remaining shows.

Several sites sit behind Cloudflare, so all fetching uses
[`curl_cffi`](https://github.com/lexiforest/curl_cffi) with browser TLS
impersonation (rotating fingerprints across retries). Adapter-specific
protocols (WP Grid Builder pagination, ThunderTix calendar feeds, Crowdwork
APIs, Next.js data routes, a Google Calendar ICS behind a Canva site) are
documented per source in [CONTEXT.md](CONTEXT.md).

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# run one adapter ad hoc
.venv/bin/python -c "from sources import magnet; print(len(magnet.fetch()))"

# full offline test suite (Python scrapers/aggregators + Swift app logic)
./run_tests.sh
```

CI (`.github/workflows/tests.yml`) runs the Python half on every push to
`main`; the Swift logic harness runs locally only.

The iOS app lives in `ios/` (SwiftUI; one Swift package dependency,
[`swift-certificates`](https://github.com/apple/swift-certificates), used to
sign Apple Wallet passes on device — Xcode resolves it on first build); open
`ios/UCBShows.xcodeproj`. Architecture notes: [ios/README.md](ios/README.md).
The complete as-built reference — every source's quirks, the class-alert
watcher, the build/release runbook, simulator recipes — is
[CONTEXT.md](CONTEXT.md); open items are in [TODO.md](TODO.md).

## Privacy

No accounts of ours, no analytics, no tracking. The app offers an optional
sign-in to a **UCB** account (on ucbcomedy.com, inside the app) for
reserving free student tickets; that session stays on the device. See
[PRIVACY.md](PRIVACY.md).

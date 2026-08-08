# Improv — live comedy shows, classes & talent

**Improv** is a free iOS app that aggregates upcoming live-comedy shows,
classes, and UCB talent across **New York, Los Angeles, and Chicago** —
eleven theaters, one feed, zero backend cost.

- App Store: **Improv** (bundle `com.salimhafid.UCBShows`)
- Feeds (this repo, served from GitHub's raw CDN):
  [shows.json](https://raw.githubusercontent.com/salimhafid/improv/main/docs/shows.json) ·
  [classes.json](https://raw.githubusercontent.com/salimhafid/improv/main/docs/classes.json) ·
  [talent.json](https://raw.githubusercontent.com/salimhafid/improv/main/docs/talent.json)

## How it works

```
GitHub Actions cron (every 3 hours)
  → publish_static.py  (LOCAL_STORE_DIR=docs — the checkout IS the state)
      scraper.py   → docs/shows.json    (11 sources, per-performance)
      classes.py   → docs/classes.json  (10 sources)
      talent.py    → docs/talent.json   (UCB directory, ~2k people)
  → commits changed feeds

iOS app (ios/) fetches the raw-CDN JSON with ETag revalidation.
```

There is no server: the scrapers run on Actions, and the repo's `docs/`
folder is both the previous-run state (per-source cadences and enrichment
caches carry across runs) and the published content.

### Theaters

| City | Sources |
|---|---|
| New York | UCB, Brooklyn Comedy Collective, Magnet Theater, WGIS |
| Los Angeles | UCB, WGIS |
| Chicago | The Second City, iO Theater, The Annoyance, Logan Square Improv, The Playground Theater |

### Resilience model

Every source is fail-soft: a scrape failure — or a suspicious 200-OK page
that parses to zero items — keeps that source's last-good data (flagged
stale) instead of wiping it from the feed. Detail/bio enrichment is budgeted
per run and converges across runs; transient fetch failures are retried
rather than cached as empty. `publish_static.py` refuses to overwrite a feed
with emptiness when nothing scraped successfully. Upcoming-ness is judged in
each venue's own timezone, so evening scrape runs don't drop that night's
remaining shows.

Several sites sit behind Cloudflare, so all fetching uses
[`curl_cffi`](https://github.com/lexiforest/curl_cffi) with browser TLS
impersonation. Adapter-specific protocols (WP Grid Builder pagination,
ThunderTix calendar feeds, Crowdwork APIs, Next.js data routes, a Google
Calendar ICS behind a Canva site) are documented per source in
[CONTEXT.md](CONTEXT.md).

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# run one adapter ad hoc
.venv/bin/python -c "from sources import magnet; print(len(magnet.fetch()))"

# full offline test suite (Python scrapers/aggregators + Swift app logic)
./run_tests.sh
```

The iOS app lives in `ios/` (SwiftUI, no dependencies); open
`ios/UCBShows.xcodeproj`. Architecture notes: [ios/README.md](ios/README.md).
The complete as-built reference — every source's quirks, the build/release
runbook, simulator recipes — is [CONTEXT.md](CONTEXT.md); open items are in
[TODO.md](TODO.md).

## Privacy

No accounts, no analytics, no tracking. See [PRIVACY.md](PRIVACY.md).

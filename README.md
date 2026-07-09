# UCB New York — Upcoming Shows

Scrapes **all upcoming New York shows** from [ucbcomedy.com/shows/new-york](https://ucbcomedy.com/shows/new-york/),
refreshes **every hour in the cloud**, and serves a polished, filterable page plus
a canonical JSON feed.

## How it works

```
Cloud Scheduler (hourly, 0 * * * *, America/New_York)
        │  HTTPS POST /refresh  (OIDC + X-Refresh-Token header)
        ▼
Cloud Run service  ──reads/writes──►  GCS bucket (last-good shows.json)
   GET  /            polished, filterable HTML (show data inlined)
   GET  /shows.json  canonical JSON payload
   GET  /status      health check
   POST /refresh     re-scrape UCB → update GCS + in-memory cache
```

- **Cloudflare bypass:** the UCB page is behind Cloudflare's managed challenge, so a
  plain HTTP client gets a 403. `scraper.py` uses [`curl_cffi`](https://github.com/lexiforest/curl_cffi)
  with browser TLS impersonation (rotating `chrome`/`chrome120`/`safari`) to fetch the
  real HTML — no headless browser needed.
- **Parsing:** the shows are server-rendered as WP Grid Builder `article.wpgb-card`
  elements; BeautifulSoup extracts title, URL, date/time (incl. multi-day festival
  ranges), venue, comedy types, image, and excerpt. Past-dated entries are dropped.
- **Resilience:** the latest payload is cached in memory and in GCS. Cold starts serve
  the last-good data instantly; if a scrape fails, the previous data is kept rather than
  served empty.

## Files

| File | Purpose |
|------|---------|
| `scraper.py` | Fetch (curl_cffi) + parse (bs4) → list of shows; runnable standalone |
| `app.py` | Flask app: `/`, `/shows.json`, `/status`, `/refresh` |
| `storage.py` | GCS last-good cache (load/save) |
| `templates/index.html` | Polished, filterable UI (dark theme, client-side filters) |
| `build_local.py` | Generate the self-contained **local** site (`site/index.html`) + optional local server |
| `serve-local.sh` | One-command local site, refreshing hourly |
| `Dockerfile` | Container for Cloud Run (python:3.12-slim + gunicorn) |
| `deploy.sh` | One-shot, idempotent GCP deploy |
| `requirements.txt` | Pinned deps |

## Deploy

```bash
bash deploy.sh
```

Defaults: project `storage-dashboards`, region `us-central1`, public access. Override
with env vars, e.g. `PROJECT=my-proj REGION=us-east1 bash deploy.sh`. The script enables
APIs, creates the bucket + service account, builds & deploys Cloud Run, sets public IAM
(falling back to authenticated-only if org policy blocks it), and creates the hourly
Scheduler job. It prints the live URL at the end.

> **Note:** `storage-dashboards` has enforced org policies and an autonomous Cloud Run
> "healer". If public access is blocked, the deploy automatically falls back to
> authenticated-only and tells you. The healer may also modify/restart the service.

## Local website (no cloud)

Generate a **self-contained static site** — `site/index.html` with all show data
inlined, so it opens straight from the filesystem (`file://`) with no server, no
network, no CORS:

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

python build_local.py            # scrape → site/index.html (+ site/shows.json)
python build_local.py --open     # …and open it in your browser
open site/index.html             # open the snapshot any time
```

It's a point-in-time snapshot — re-run to refresh. For a **living local site that
refreshes itself hourly**:

```bash
bash serve-local.sh              # http://localhost:8086, re-scrapes every hour
# equivalently:
python build_local.py --serve --loop --open
```

Other flags: `--from-json shows.json` (rebuild offline, no scraping), `--interval N`
(refresh seconds), `--port N`, `--host 0.0.0.0` (share on your LAN; default is
loopback-only). If a startup scrape fails, serve mode still comes up serving the last
good `site/index.html` while it retries in the background.

The static site uses the **same template** as the cloud app, so it looks identical.
Poster images load from ucbcomedy.com when you're online.

## Run the full app locally

```bash
python scraper.py            # prints the JSON payload (no GCS needed)
python app.py                # serves http://localhost:8080  (BUCKET unset → GCS no-ops)
```

To exercise `/refresh` locally: `REFRESH_TOKEN=dev python app.py`, then
`curl -X POST -H 'X-Refresh-Token: dev' localhost:8080/refresh`.

## Operate

- **Force a refresh now:** `gcloud scheduler jobs run ucb-hourly --location us-central1`
- **Logs:** `gcloud run services logs read ucb-ny-shows --region us-central1`
- **Change cadence:** edit the `--schedule` cron in `deploy.sh` and re-run, or
  `gcloud scheduler jobs update http ucb-hourly --schedule="*/30 * * * *" --location us-central1`

## Cost

Cloud Run scales to zero; one Scheduler job (free tier covers 3); GCS stores a few KB.
Effectively free for personal use.

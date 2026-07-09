"""Build a self-contained LOCAL website of UCB New York shows.

Renders the exact same Jinja template the Cloud Run app uses into a standalone
`site/index.html` with the show data inlined — so it opens directly from the
filesystem (file://) with no server, no network, and no CORS issues. Also writes
`site/shows.json` alongside it.

Usage:
  python build_local.py                       # scrape fresh -> site/index.html (+ shows.json)
  python build_local.py --from-json PATH      # build from an existing payload (no network)
  python build_local.py --open                # build, then open in your browser
  python build_local.py --serve [--port 8086] # build, then serve site/ at localhost
  python build_local.py --serve --loop        # serve + re-scrape on an interval
  python build_local.py --serve --loop --interval 1800   # custom interval (seconds)

The default static file is a point-in-time snapshot — re-run to refresh it. Use
--serve --loop if you want a long-running local site that refreshes itself.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import threading
import time
import webbrowser
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape

from scraper import build_payload, filter_payload, scrape

log = logging.getLogger("ucb.build_local")

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES_DIR = os.path.join(HERE, "templates")
SITE_DIR = os.path.join(HERE, "site")

# Jinja2 ships a built-in `tojson` filter (escapes </script> etc.), so the same
# template renders standalone without Flask.
_env = Environment(
    loader=FileSystemLoader(TEMPLATES_DIR),
    autoescape=select_autoescape(["html", "xml"]),
)


def _atomic_write(path: str, data: str) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data)
    os.replace(tmp, path)


def build(payload: dict, site_dir: str = SITE_DIR) -> str:
    """Render payload -> site/index.html (+ shows.json). Returns index.html path."""
    os.makedirs(site_dir, exist_ok=True)
    payload = filter_payload(payload, {"ucb_ny"})   # local site stays UCB New York
    html = _env.get_template("index.html").render(payload=payload, hourly=False)
    index_path = os.path.join(site_dir, "index.html")
    _atomic_write(index_path, html)
    _atomic_write(os.path.join(site_dir, "shows.json"),
                  json.dumps(payload, ensure_ascii=False, indent=2))
    log.info("wrote %s (%d shows, %d bytes)", index_path, payload.get("count", 0), len(html))
    return index_path


def _file_url(path: str) -> str:
    """A valid file:// URL (percent-encodes spaces etc.) for the local path."""
    return Path(path).resolve().as_uri()


def _payload_from_args(args) -> dict:
    if args.from_json:
        try:
            with open(args.from_json, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise SystemExit(f"cannot read {args.from_json}: {e}")
        # Accept either a full payload {..., "shows": [...]} or a bare list.
        if isinstance(data, dict) and "shows" in data:
            return data
        if isinstance(data, list):
            return build_payload(data)
        raise SystemExit(f"unrecognized JSON shape in {args.from_json}")
    return scrape()


def _make_server(host: str, port: int) -> ThreadingHTTPServer:
    handler = partial(SimpleHTTPRequestHandler, directory=SITE_DIR)
    return ThreadingHTTPServer((host, port), handler)


def _refresh_loop(site_dir: str, interval: int) -> None:
    while True:
        time.sleep(interval)
        try:
            build(scrape(), site_dir)
            log.info("refreshed; next in %ds", interval)
        except Exception as e:  # noqa: BLE001 - keep last-good site on failure
            log.error("refresh failed (keeping last-good): %r", e)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Build a local UCB NY shows website.")
    p.add_argument("--from-json", help="build from an existing shows.json instead of scraping")
    p.add_argument("--open", action="store_true", help="open the built file in your browser")
    p.add_argument("--serve", action="store_true", help="serve site/ over http after building")
    p.add_argument("--loop", action="store_true", help="with --serve, re-scrape on an interval")
    p.add_argument("--interval", type=int, default=3600, help="refresh seconds for --loop (default 3600)")
    p.add_argument("--port", type=int, default=8086, help="port for --serve (default 8086)")
    p.add_argument("--host", default="127.0.0.1",
                   help="bind address for --serve (default 127.0.0.1; use 0.0.0.0 to share on LAN)")
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(message)s")

    index_path = os.path.join(SITE_DIR, "index.html")

    # Build the site. In serve mode a startup scrape failure (e.g. a transient
    # Cloudflare challenge) must not stop us from serving a previously-built
    # site while the refresh loop retries.
    try:
        build(_payload_from_args(args))
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001
        if args.serve and os.path.exists(index_path):
            log.error("initial build failed; serving last-good site and retrying: %r", e)
        else:
            raise SystemExit(f"build failed: {e}")

    if not args.serve:
        if args.open:
            webbrowser.open(_file_url(index_path))
        print(f"\n  Built: {index_path}")
        print(f"  Open it directly:  open '{index_path}'\n")
        return 0

    # Serve mode: bind first, then open the browser (avoids a connection-refused
    # race), then serve. Start the refresh loop in the background if requested.
    if args.loop:
        threading.Thread(target=_refresh_loop, args=(SITE_DIR, args.interval),
                         daemon=True).start()
    httpd = _make_server(args.host, args.port)
    url = f"http://localhost:{args.port}/"
    log.info("serving %s at %s  (Ctrl+C to stop)", SITE_DIR, url)
    print(f"\n  Local website: {url}\n")
    if args.open:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

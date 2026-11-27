"""Check the last successful UCB scrapes in the published static feeds."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


EXPECTED_SOURCES = {
    "classes.json": ("ucb_ny", "ucb_la", "ucb_online"),
    "shows.json": ("ucb_ny", "ucb_la"),
}
MAX_AGE = timedelta(hours=2)


def check_feed(path: Path, now: datetime) -> list[str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"{path}: could not read feed: {error}"]
    sources = payload.get("sources") if isinstance(payload, dict) else None
    if not isinstance(sources, list):
        return [f"{path}: missing or invalid sources list"]

    errors = []
    for school in EXPECTED_SOURCES[path.name]:
        label = f"{path.name}/{school}"
        rows = [row for row in sources if isinstance(row, dict) and row.get("id") == school]
        if len(rows) != 1:
            errors.append(f"{label}: expected one source summary, found {len(rows)}")
            continue
        row = rows[0]
        stamp = row.get("scraped_at")
        if row.get("ok") is not True or row.get("stale") is not False or row.get("error"):
            reason = row.get("error") or "source reported stale or unsuccessful scrape"
            errors.append(f"{label}: {reason}. Last successful scrape: {stamp or 'unknown'}")
            continue
        try:
            scraped_at = datetime.fromisoformat(stamp.replace("Z", "+00:00")) if isinstance(stamp, str) else None
        except ValueError:
            scraped_at = None
        if scraped_at is None or scraped_at.tzinfo is None:
            errors.append(f"{label}: missing or invalid timestamp for the last successful scrape: {stamp!r}")
        elif not timedelta(0) <= now - scraped_at <= MAX_AGE:
            errors.append(f"{label}: last successful scrape {stamp} is outside the preceding two hours")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="directory containing the published JSON feeds")
    parser.add_argument("--classes-only", action="store_true", help="check only classes.json")
    args = parser.parse_args()
    now = datetime.now(timezone.utc)
    feeds = ["classes.json"] if args.classes_only else EXPECTED_SOURCES
    errors = [error for name in feeds for error in check_feed(args.directory / name, now)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"UCB sources have successful scrapes within two hours in {', '.join(feeds)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

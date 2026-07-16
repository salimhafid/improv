"""UCB talent directory aggregator.

Merges the three talent pages (NY performers, DCM talent, teachers) into one
payload keyed by profile slug, with each person tagged by the groups they
appear in. A failed page carries over that group's people from the previous
payload so a transient block never empties the directory.

Runnable standalone: `python talent.py` prints the JSON payload.
"""
from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone

import storage
from sources.ucb_talent import PAGES, fetch_page

log = logging.getLogger("ucb.talent")


def aggregate_talent(now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    previous = storage.load_talent() or {}
    prev_people = previous.get("people", [])

    people: dict[str, dict] = {}   # slug → person
    summary: list[dict] = []

    for group, url in PAGES:
        try:
            page_people = fetch_page(url)
            for p in page_people:
                dcm = p.pop("dcm", False)
                entry = people.setdefault(p["slug"], {**p, "groups": []})
                if group not in entry["groups"]:
                    entry["groups"].append(group)
                if dcm and "dcm" not in entry["groups"]:
                    entry["groups"].append("dcm")
                if not entry.get("image") and p.get("image"):
                    entry["image"] = p["image"]
            summary.append({"id": group, "count": len(page_people), "ok": True, "error": None})
            log.info("talent page %s: %d people", group, len(page_people))
        except Exception as e:  # noqa: BLE001 - carry the group from last-good
            carried = 0
            for prev in prev_people:
                if group in prev.get("groups", []):
                    entry = people.setdefault(prev["slug"], {**prev, "groups": []})
                    if group not in entry["groups"]:
                        entry["groups"].append(group)
                    carried += 1
            summary.append({"id": group, "count": carried, "ok": bool(carried), "error": str(e)})
            log.warning("talent page %s failed: %r (carried %d)", group, e, carried)

    ordered = sorted(people.values(), key=lambda p: p["name"].lower())
    return {
        "generated_at": now.isoformat(),
        "count": len(ordered),
        "sources": summary,
        "people": ordered,
    }


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    print(json.dumps(aggregate_talent(), indent=2, ensure_ascii=False))

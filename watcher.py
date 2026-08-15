"""Class-alert watcher: detects newly posted classes and writes CloudKit
records that fan out as push notifications (via each device's
CKQuerySubscriptions — see the app's ClassAlertsStore).

Two modes, run by .github/workflows/class-watch.yml:

  --ucb    every 10 minutes: one Arlo catalog pull, split into
           ucb_ny / ucb_la / ucb_online by LOC_* tag, categorized by CTG_* tag.
           New classes alert per (school, category) so devices subscribed to
           only some categories get only those pushes.
  --all    daily: every non-UCB class source; new classes alert per school
           as a single daily bundle (category "all").

State (known class ids per school) lives in state/class-watch.json on the
`class-watch-state` branch — the workflow checks it out and commits it back.
A school with NO prior state is baselined silently (no alert flood on the
first run). CloudKit credentials come from the environment; without them the
watcher runs in dry-run mode and just prints what it would send.

CloudKit auth: server-to-server key (CloudKit Console) — ECDSA P-256 over
"<iso-date>:<sha256-b64 of body>:<subpath>" per Apple's spec.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone

log = logging.getLogger("ucb.watcher")

STATE_PATH = os.environ.get("WATCH_STATE", "state/class-watch.json")
CONTAINER = os.environ.get("CLOUDKIT_CONTAINER", "iCloud.com.salimhafid.UCBShows")
KEY_ID = os.environ.get("CLOUDKIT_KEY_ID", "")
PRIVATE_KEY_PEM = os.environ.get("CLOUDKIT_PRIVATE_KEY", "")
ENVIRONMENTS = [e for e in os.environ.get("CLOUDKIT_ENVS", "development,production").split(",") if e]

DISPLAY = {
    "ucb_ny": "UCB New York", "ucb_la": "UCB Los Angeles", "ucb_online": "UCB Online",
    "brooklyn_cc": "Brooklyn Comedy Collective", "magnet": "Magnet Theater",
    "wgis_ny": "WGIS New York", "wgis_la": "WGIS Los Angeles",
    "annoyance": "The Annoyance", "io_chicago": "iO Theater",
    "second_city": "The Second City", "logan_square": "Logan Square Improv",
}

# Arlo tag → canonical category key (first match wins; order = priority).
UCB_CATEGORY_TAGS = [
    ("CTG_Improv_Electives", "improv_electives"),
    ("CTG_Improv", "improv"),
    ("CTG_Sketch_Electives", "sketch_electives"),
    ("CTG_Sketch_Character", "sketch_character"),
    ("CTG_Musical_Improv", "musical_improv"),
    ("CTG_Standup", "standup"),
    ("CTG_Clowning", "clowning"),
    ("CTG_Acting", "acting"),
    ("CTG_Writing_Programs", "writing_programs"),
    ("CTG_Featured_Programs", "featured_programs"),
    ("FRQ_Workshop", "workshops"),
    ("FRQ_Intensive", "intensives"),
]

CATEGORY_LABEL = {
    "improv": "Improv", "improv_electives": "Improv Electives",
    "sketch_character": "Sketch & Character", "sketch_electives": "Sketch Electives",
    "musical_improv": "Musical Improv", "standup": "Stand-Up",
    "clowning": "Clowning", "acting": "Acting",
    "writing_programs": "Writing Programs", "featured_programs": "Featured Programs",
    "workshops": "Workshops", "intensives": "Intensives", "other": "Other",
}

UCB_LOCATIONS = [("LOC_NY", "ucb_ny"), ("LOC_LA", "ucb_la"), ("LOC_Online", "ucb_online")]


def _category(tags: list[str]) -> str:
    for tag, key in UCB_CATEGORY_TAGS:
        if tag in tags:
            return key
    return "other"


def scan_ucb() -> dict[str, dict[str, dict]]:
    """Arlo catalog → {school: {class_id: {title, when, category}}}."""
    from common import clean
    from sources.ucb_classes import raw_events

    out: dict[str, dict[str, dict]] = {s: {} for _, s in UCB_LOCATIONS}
    for ev in raw_events():
        tags = ev.get("Tags") or []
        title = clean(ev.get("Name"))
        if not title:
            continue
        for tag, school in UCB_LOCATIONS:
            if tag in tags:
                when = (ev.get("StartDateTime") or "")[:10]
                out[school][str(ev.get("EventID"))] = {
                    "title": title, "when": when, "category": _category(tags),
                }
    return out


def scan_others() -> dict[str, dict[str, dict]]:
    """Every non-UCB class source → {school: {class_id: {title, when}}}.
    A source that raises is skipped (state untouched → retried next run)."""
    from sources import CLASS_SOURCES

    out: dict[str, dict[str, dict]] = {}
    for src in CLASS_SOURCES:
        if src["id"].startswith("ucb"):
            continue
        try:
            items = src["fetch"]()
        except Exception as e:  # noqa: BLE001 — one bad source must not kill the run
            log.warning("%s failed: %r", src["id"], e)
            continue
        out[src["id"]] = {
            str(c.get("id")): {"title": c.get("title") or "", "when": (c.get("start") or "")[:10]}
            for c in items if c.get("id")
        }
    return out


def load_state() -> dict:
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_PATH) or ".", exist_ok=True)
    with open(STATE_PATH, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, sort_keys=True)


def diff_and_alert(scanned: dict[str, dict[str, dict]], state: dict, per_category: bool) -> list[dict]:
    """Update state and return alert payloads for genuinely new classes."""
    alerts: list[dict] = []
    now = datetime.now(timezone.utc).isoformat()
    for school, current in scanned.items():
        prior = state.get(school)
        state[school] = {"ids": sorted(current.keys()), "updated": now}
        if prior is None:
            log.info("%s: baselined %d classes (no alerts on first sight)", school, len(current))
            continue
        known = set(prior.get("ids") or [])
        new = [meta | {"id": cid} for cid, meta in current.items() if cid not in known]
        if not new:
            continue
        groups: dict[str, list[dict]] = {}
        for item in new:
            key = item.get("category", "all") if per_category else "all"
            groups.setdefault(key, []).append(item)
        for category, items in sorted(groups.items()):
            alerts.append(compose(school, category, items))
    return alerts


def compose(school: str, category: str, items: list[dict]) -> dict:
    name = DISPLAY.get(school, school)
    titles = [i["title"] for i in items]
    if school.startswith("ucb"):
        label = CATEGORY_LABEL.get(category, "")
        if len(items) == 1:
            title = f"New class at {name}"
            body = titles[0] + (f" · starts {items[0]['when']}" if items[0].get("when") else "")
        else:
            title = f"New {label} classes at {name}" if label else f"New classes at {name}"
            body = _list_body(titles)
    else:
        title = f"New class at {name}" if len(items) == 1 else f"New classes at {name}"
        body = titles[0] if len(items) == 1 else _list_body(titles)
    return {
        "school": school, "category": category, "count": len(items),
        "pushTitle": title, "pushBody": body,
        "classIDs": ",".join(i["id"] for i in items)[:900],
    }


def _list_body(titles: list[str]) -> str:
    shown = titles[:3]
    more = len(titles) - len(shown)
    body = " · ".join(shown)
    if more > 0:
        body += f" and {more} more"
    return body[:170]


# ---------- CloudKit server-to-server ----------

def _sign(subpath: str, body: bytes) -> dict[str, str]:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body_hash = base64.b64encode(hashlib.sha256(body).digest()).decode()
    message = f"{date}:{body_hash}:{subpath}".encode()
    key = serialization.load_pem_private_key(PRIVATE_KEY_PEM.encode(), password=None)
    signature = base64.b64encode(key.sign(message, ec.ECDSA(hashes.SHA256()))).decode()
    return {
        "X-Apple-CloudKit-Request-KeyID": KEY_ID,
        "X-Apple-CloudKit-Request-ISO8601Date": date,
        "X-Apple-CloudKit-Request-SignatureV1": signature,
        "Content-Type": "application/json",
    }


def send_alerts(alerts: list[dict]) -> None:
    import urllib.request

    if not alerts:
        log.info("nothing new")
        return
    if not KEY_ID or not PRIVATE_KEY_PEM:
        log.warning("DRY RUN (no CloudKit key configured) — would send:")
        for a in alerts:
            log.warning("  [%s/%s] %s — %s", a["school"], a["category"], a["pushTitle"], a["pushBody"])
        return

    batch = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for env in ENVIRONMENTS:
        subpath = f"/database/1/{CONTAINER}/{env}/public/records/modify"
        operations = [{
            "operationType": "create",
            "record": {
                "recordType": "ClassAlert",
                "recordName": f"alert-{batch}-{a['school']}-{a['category']}-{uuid.uuid4().hex[:8]}",
                "fields": {
                    "school": {"value": a["school"]},
                    "category": {"value": a["category"]},
                    "count": {"value": a["count"]},
                    "pushTitle": {"value": a["pushTitle"]},
                    "pushBody": {"value": a["pushBody"]},
                    "classIDs": {"value": a["classIDs"]},
                },
            },
        } for a in alerts]
        body = json.dumps({"operations": operations}).encode()
        req = urllib.request.Request(
            "https://api.apple-cloudkit.com" + subpath, data=body,
            headers=_sign(subpath, body), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.load(resp)
            errors = [r for r in result.get("records", []) if r.get("serverErrorCode")]
            log.info("%s: wrote %d alert record(s), %d error(s)",
                     env, len(alerts) - len(errors), len(errors))
            for e in errors[:3]:
                log.warning("  %s: %s", env, e.get("serverErrorCode"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            log.error("%s: CloudKit HTTP %d: %s", env, e.code, body[:500])
        except Exception as e:  # noqa: BLE001
            log.error("%s: CloudKit write failed: %r", env, e)


def test_cloudkit() -> int:
    """Send a single test record to verify CloudKit auth, then delete it."""
    import urllib.error
    import urllib.request
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    if not KEY_ID or not PRIVATE_KEY_PEM:
        log.error("CLOUDKIT_KEY_ID and CLOUDKIT_PRIVATE_KEY must be set")
        return 1

    log.info("Key ID: %s...%s (%d chars)", KEY_ID[:8], KEY_ID[-4:], len(KEY_ID))
    pem = PRIVATE_KEY_PEM.strip()
    log.info("PEM starts with: %s", pem[:30])
    log.info("PEM has %d lines, %d total chars", pem.count("\n") + 1, len(pem))
    try:
        key = serialization.load_pem_private_key(pem.encode(), password=None)
        if isinstance(key, ec.EllipticCurvePrivateKey):
            log.info("Key type: EC %s (%d-bit)", key.curve.name, key.key_size)
            pub_bytes = key.public_key().public_bytes(
                serialization.Encoding.X962,
                serialization.PublicFormat.UncompressedPoint)
            log.info("Public key (uncompressed): %d bytes", len(pub_bytes))
        else:
            log.error("Key is not EC: %s", type(key).__name__)
            return 1
    except Exception as e:
        log.error("Failed to load PEM: %r", e)
        return 1

    log.info("Container: %s", CONTAINER)
    log.info("Environments: %s", ENVIRONMENTS)

    record_name = f"test-{uuid.uuid4().hex[:12]}"
    for env in ENVIRONMENTS:
        subpath = f"/database/1/{CONTAINER}/{env}/public/records/modify"
        body = json.dumps({"operations": [{
            "operationType": "create",
            "record": {
                "recordType": "ClassAlert",
                "recordName": record_name,
                "fields": {
                    "school": {"value": "__test__"},
                    "category": {"value": "test"},
                    "count": {"value": 0},
                    "pushTitle": {"value": "CloudKit auth test"},
                    "pushBody": {"value": "This record can be deleted."},
                    "classIDs": {"value": ""},
                },
            },
        }]}).encode()
        req = urllib.request.Request(
            "https://api.apple-cloudkit.com" + subpath, data=body,
            headers=_sign(subpath, body), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.load(resp)
            records = result.get("records", [])
            errors = [r for r in records if r.get("serverErrorCode")]
            if errors:
                log.error("%s: server error: %s", env, errors[0])
            else:
                log.info("%s: auth OK — wrote test record %s", env, record_name)
                _delete_record(env, record_name)
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", errors="replace")
            log.error("%s: HTTP %d: %s", env, e.code, body_text[:500])
            return 1
        except Exception as e:  # noqa: BLE001
            log.error("%s: %r", env, e)
            return 1
    return 0


def _delete_record(env: str, record_name: str) -> None:
    import urllib.request

    subpath = f"/database/1/{CONTAINER}/{env}/public/records/modify"
    body = json.dumps({"operations": [{
        "operationType": "delete",
        "record": {"recordType": "ClassAlert", "recordName": record_name},
    }]}).encode()
    req = urllib.request.Request(
        "https://api.apple-cloudkit.com" + subpath, data=body,
        headers=_sign(subpath, body), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15):
            log.info("%s: cleaned up test record", env)
    except Exception:  # noqa: BLE001
        log.warning("%s: could not delete test record %s", env, record_name)


def main() -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    ap = argparse.ArgumentParser()
    ap.add_argument("--ucb", action="store_true", help="scan UCB (NY/LA/Online) via Arlo")
    ap.add_argument("--all", action="store_true", help="scan every non-UCB class source")
    ap.add_argument("--test", action="store_true", help="send a test record to verify CloudKit auth")
    args = ap.parse_args()

    if args.test:
        return test_cloudkit()

    if not (args.ucb or args.all):
        ap.error("pass --ucb and/or --all")

    state = load_state()
    alerts: list[dict] = []
    if args.ucb:
        alerts += diff_and_alert(scan_ucb(), state, per_category=True)
    if args.all:
        alerts += diff_and_alert(scan_others(), state, per_category=False)
    save_state(state)
    send_alerts(alerts)
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Class-alert watcher: detects newly posted classes and writes CloudKit
records that fan out as push notifications (via each device's
CKQuerySubscriptions — see the app's ClassAlertsStore).

Two modes, run by .github/workflows/class-watch.yml — a self-perpetuating
job that loops "run, sleep 10 min" for ~5.5 h and then dispatches its own
successor, because GitHub delays *scheduled* runs by hours but not running
ones. Three staggered odd-minute crons (class-watch-kick-*.yml) only restart
the chain if it has died.

  --ucb    every iteration: one Arlo catalog pull, split into
           ucb_ny / ucb_la / ucb_online by LOC_* tag, categorized by CTG_* tag.
           New classes are bundled per (school, category set) — a record lists
           every category its classes carry, and a device's subscription
           matches on any one of them.
  --all    every non-UCB class source; new classes alert per school as one
           bundle (category "all"). The chain passes --all-if-stale 20 so this
           stays a roughly daily scan rather than one per iteration.

State (known class ids per school) lives in class-watch.json at the root of
the `class-watch-state` branch — the workflow checks it out into state-branch/
and points WATCH_STATE at it, then commits it back. (The bare default,
state/class-watch.json, is only for local runs.)
A school with NO prior state is baselined silently (no alert flood on the
first run). A scan that comes back EMPTY for a school that had classes is
treated as a failed scan (markup change, transient empty body): its state is
left alone and nothing is alerted, so the next good scan doesn't see every
class as new. Alerts are at-least-once: they are sent before state is saved,
and any that a CloudKit environment failed to accept are parked under
`_pending_alerts` and retried on the next iteration (main() exits non-zero
so the workflow's ::warning fires). CloudKit credentials come from the
environment; without them the watcher runs in dry-run mode and just prints
what it would send.

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
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

log = logging.getLogger("ucb.watcher")

STATE_PATH = os.environ.get("WATCH_STATE", "state/class-watch.json")
CONTAINER = os.environ.get("CLOUDKIT_CONTAINER", "iCloud.com.salimhafid.UCBShows")
KEY_ID = os.environ.get("CLOUDKIT_KEY_ID", "")
KEY_ID_PROD = os.environ.get("CLOUDKIT_KEY_ID_PROD", "")
PRIVATE_KEY_PEM = os.environ.get("CLOUDKIT_PRIVATE_KEY", "")
ENVIRONMENTS = [e.strip() for e in os.environ.get("CLOUDKIT_ENVS", "development,production").split(",")
                if e.strip()]
PENDING_KEY = "_pending_alerts"   # state slot for alerts CloudKit hasn't accepted yet
_MAX_PENDING = 50                 # bound the state file if an env stays broken


def _key_id(env: str) -> str:
    if env == "production" and KEY_ID_PROD:
        return KEY_ID_PROD
    return KEY_ID

DISPLAY = {
    "ucb_ny": "UCB New York", "ucb_la": "UCB Los Angeles", "ucb_online": "UCB Online",
    "brooklyn_cc": "Brooklyn Comedy Collective", "magnet": "Magnet Theater",
    "wgis_ny": "WGIS New York", "wgis_la": "WGIS Los Angeles",
    "annoyance": "The Annoyance", "io_chicago": "iO Theater",
    "second_city": "The Second City", "logan_square": "Logan Square Improv",
}

# Arlo tag → canonical category key. Order = priority: the first match is the
# record's primary `category`; every match lands in `categories`.
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


def _categories(tags: list[str]) -> list[str]:
    """Every category a class carries, in priority order. A workshop tagged
    Featured Programs + Improv Electives + Sketch Electives is all three, and
    a device subscribed to any one of them should hear about it — picking only
    the first is how a Kevin McDonald workshop went out as `improv_electives`
    alone and reached nobody subscribed to Improv, Sketch, or Featured."""
    keys = [key for tag, key in UCB_CATEGORY_TAGS if tag in tags]
    return keys or ["other"]


def _category(tags: list[str]) -> str:
    """Primary category — the first match. Still written as the record's
    scalar `category` so builds subscribed on `category ==` keep matching."""
    return _categories(tags)[0]


def scan_ucb() -> dict[str, dict[str, dict]]:
    """Arlo catalog → {school: {class_id: {title, when, category}}}."""
    from common import clean
    from sources.ucb_classes import raw_events

    out: dict[str, dict[str, dict]] = {s: {} for _, s in UCB_LOCATIONS}
    for ev in raw_events():
        tags = ev.get("Tags") or []
        title = clean(ev.get("Name"))
        if not title or not ev.get("EventID"):
            continue
        for tag, school in UCB_LOCATIONS:
            if tag in tags:
                when = (ev.get("StartDateTime") or "")[:10]
                out[school][str(ev.get("EventID"))] = {
                    "title": title, "when": when, "categories": _categories(tags),
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


def others_stale(state: dict, hours: float) -> bool:
    """True when the non-UCB schools haven't been scanned within `hours` — or
    never have. Lets a job that runs every 10 minutes keep the other schools on
    a daily cadence without a second workflow racing it for the state branch."""
    stamps = [v.get("updated") for k, v in state.items()
              if not k.startswith("ucb") and isinstance(v, dict)]
    stamps = [t for t in stamps if t]
    if not stamps:
        return True
    newest = datetime.fromisoformat(max(stamps))
    if newest.tzinfo is None:
        newest = newest.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - newest).total_seconds() > hours * 3600


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
        if prior is not None and not isinstance(prior, dict):
            log.warning("%s: corrupt state entry %r — re-baselining", school, prior)
            prior = None
        if not current and prior and prior.get("ids"):
            # An empty scan of a school that had classes is a failed scan, not
            # a school with no classes: keep the prior ids so the next good
            # scan doesn't alert on every one of them.
            log.warning("%s: scan returned no classes (had %d); keeping prior state, no alerts",
                        school, len(prior["ids"]))
            continue
        state[school] = {"ids": sorted(current.keys()), "updated": now}
        if prior is None:
            log.info("%s: baselined %d classes (no alerts on first sight)", school, len(current))
            continue
        known = set(prior.get("ids") or [])
        new = [meta | {"id": cid} for cid, meta in current.items() if cid not in known]
        if not new:
            continue
        groups: dict[tuple[str, ...], list[dict]] = {}
        for item in new:
            key = tuple(item.get("categories") or ["other"]) if per_category else ("all",)
            groups.setdefault(key, []).append(item)
        for categories, items in sorted(groups.items()):
            alerts.append(compose(school, list(categories), items))
    return alerts


def compose(school: str, categories: list[str], items: list[dict]) -> dict:
    """One alert payload. `categories` is the full set every item carries;
    `category` (its first entry) is the primary, kept for older subscribers."""
    name = DISPLAY.get(school, school)
    titles = [i["title"] for i in items]
    category = categories[0]
    if school.startswith("ucb"):
        label = CATEGORY_LABEL.get(category, "")
        if len(items) == 1:
            title = f"New class at {name}"
            body = (titles[0] + (f" · starts {items[0]['when']}" if items[0].get("when") else ""))[:170]
        else:
            title = f"New {label} classes at {name}" if label else f"New classes at {name}"
            body = _list_body(titles)
    else:
        title = f"New class at {name}" if len(items) == 1 else f"New classes at {name}"
        body = titles[0] if len(items) == 1 else _list_body(titles)
    return {
        "school": school, "category": category, "categories": categories,
        "count": len(items), "pushTitle": title, "pushBody": body,
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

def _sign(subpath: str, body: bytes, env: str) -> dict[str, str]:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body_hash = base64.b64encode(hashlib.sha256(body).digest()).decode()
    message = f"{date}:{body_hash}:{subpath}".encode()
    key = serialization.load_pem_private_key(PRIVATE_KEY_PEM.encode(), password=None)
    der_sig = key.sign(message, ec.ECDSA(hashes.SHA256()))
    signature = base64.b64encode(der_sig).decode()
    return {
        "X-Apple-CloudKit-Request-KeyID": _key_id(env),
        "X-Apple-CloudKit-Request-ISO8601Date": date,
        "X-Apple-CloudKit-Request-SignatureV1": signature,
        "Content-Type": "application/json",
    }


def send_alerts(alerts: list[dict]) -> list[dict]:
    """Write one ClassAlert record per alert to every environment. Returns the
    alerts that some environment did NOT accept (HTTP/auth/network failure or
    a per-record server error), each tagged with `envs` = the environments
    still owed, so the caller can park them for a retry. An alert carrying
    `envs` from an earlier retry only goes to those environments."""
    if not alerts:
        log.info("nothing new")
        return []
    if not KEY_ID or not PRIVATE_KEY_PEM:
        log.warning("DRY RUN (no CloudKit key configured) — would send:")
        for a in alerts:
            log.warning("  [%s/%s] %s — %s", a["school"], "+".join(a["categories"]),
                        a["pushTitle"], a["pushBody"])
        return []

    batch = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    unsent: dict[int, list[str]] = {}   # alert index → environments still owed
    for env in ENVIRONMENTS:
        targets = [(i, a) for i, a in enumerate(alerts) if env in (a.get("envs") or ENVIRONMENTS)]
        if not targets:
            continue
        subpath = f"/database/1/{CONTAINER}/{env}/public/records/modify"
        names = {f"alert-{batch}-{a['school']}-{a['category']}-{uuid.uuid4().hex[:8]}": i
                 for i, a in targets}
        operations = [{
            "operationType": "create",
            "record": {
                "recordType": "ClassAlert",
                "recordName": name,
                "fields": {
                    "school": {"value": a["school"], "type": "STRING"},
                    "category": {"value": a["category"], "type": "STRING"},
                    "categories": {"value": a["categories"], "type": "STRING_LIST"},
                    "count": {"value": a["count"], "type": "INT64"},
                    "pushTitle": {"value": a["pushTitle"], "type": "STRING"},
                    "pushBody": {"value": a["pushBody"], "type": "STRING"},
                    "classIDs": {"value": a["classIDs"], "type": "STRING"},
                },
            },
        } for name, (i, a) in zip(names, targets)]
        body = json.dumps({"operations": operations}).encode()
        try:
            # _sign is inside the try: a malformed key must not raise out of
            # main() before the remaining environments (and state) are handled.
            req = urllib.request.Request(
                "https://api.apple-cloudkit.com" + subpath, data=body,
                headers=_sign(subpath, body, env), method="POST")
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.load(resp)
            errors = [r for r in result.get("records", []) if r.get("serverErrorCode")]
            log.info("%s: wrote %d alert record(s), %d error(s)",
                     env, len(targets) - len(errors), len(errors))
            for e in errors[:3]:
                log.warning("  %s: %s", env, e.get("serverErrorCode"))
            for e in errors:
                i = names.get(e.get("recordName"))
                if i is not None:
                    unsent.setdefault(i, []).append(env)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            log.error("%s: CloudKit HTTP %d: %s", env, e.code, body[:500])
            for i, _ in targets:
                unsent.setdefault(i, []).append(env)
        except Exception as e:  # noqa: BLE001
            log.error("%s: CloudKit write failed: %r", env, e)
            for i, _ in targets:
                unsent.setdefault(i, []).append(env)
    return [dict(alerts[i], envs=envs) for i, envs in sorted(unsent.items())]


def pending_alerts(state: dict) -> list[dict]:
    """Pop the alerts parked by an earlier iteration (tolerating a hand-edited
    or missing slot)."""
    parked = state.pop(PENDING_KEY, None)
    if not isinstance(parked, list):
        return []
    return [a for a in parked if isinstance(a, dict) and a.get("school") and a.get("category")]


def test_cloudkit(environments: list[str]) -> int:
    """Send a single test record to verify CloudKit auth, then delete it."""
    if not environments:
        log.error("no CloudKit environment to test (CLOUDKIT_ENVS=%r; pass --test-prod for production)",
                  ",".join(ENVIRONMENTS))
        return 1
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import hashes, serialization

    if not KEY_ID or not PRIVATE_KEY_PEM:
        log.error("CLOUDKIT_KEY_ID and CLOUDKIT_PRIVATE_KEY must be set")
        return 1

    try:
        key = serialization.load_pem_private_key(PRIVATE_KEY_PEM.encode(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey):
            log.error("Key is not EC: %s", type(key).__name__)
            return 1
        log.info("Key loaded: EC %s, Key ID: %s...%s",
                 key.curve.name, KEY_ID[:8], KEY_ID[-4:])
    except Exception as e:
        log.error("Failed to load PEM: %r", e)
        return 1

    ok = True
    for env in environments:
        record_name = f"test-{env}-{uuid.uuid4().hex[:8]}"
        w_subpath = f"/database/1/{CONTAINER}/{env}/public/records/modify"
        w_payload = json.dumps({"operations": [{
            "operationType": "create",
            "record": {
                "recordType": "ClassAlert",
                "recordName": record_name,
                "fields": {
                    "school": {"value": "__test__", "type": "STRING"},
                    "category": {"value": "test", "type": "STRING"},
                    "categories": {"value": ["test"], "type": "STRING_LIST"},
                    "count": {"value": 0, "type": "INT64"},
                    "pushTitle": {"value": "CloudKit auth test", "type": "STRING"},
                    "pushBody": {"value": "This record can be deleted.", "type": "STRING"},
                    "classIDs": {"value": "", "type": "STRING"},
                },
            },
        }]}).encode()
        w_req = urllib.request.Request(
            "https://api.apple-cloudkit.com" + w_subpath, data=w_payload,
            headers=_sign(w_subpath, w_payload, env), method="POST")
        try:
            with urllib.request.urlopen(w_req, timeout=30) as resp:
                result = json.load(resp)
            records = result.get("records", [])
            errors = [r for r in records if r.get("serverErrorCode")]
            if errors:
                log.error("%s: write error: %s", env, errors[0])
                ok = False
            else:
                log.info("%s: write OK — cleaning up %s", env, record_name)
                _delete_record(env, record_name)
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", errors="replace")
            log.error("%s: write HTTP %d: %s", env, e.code, body_text[:500])
            ok = False
        except Exception as e:  # noqa: BLE001
            log.error("%s: write failed: %r", env, e)
            ok = False
    return 0 if ok else 1


def _delete_record(env: str, record_name: str) -> None:
    subpath = f"/database/1/{CONTAINER}/{env}/public/records/modify"
    body = json.dumps({"operations": [{
        "operationType": "delete",
        "record": {"recordType": "ClassAlert", "recordName": record_name},
    }]}).encode()
    req = urllib.request.Request(
        "https://api.apple-cloudkit.com" + subpath, data=body,
        headers=_sign(subpath, body, env), method="POST")
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
    ap.add_argument("--all-if-stale", type=float, metavar="HOURS",
                    help="scan the non-UCB sources only if their state is older than HOURS")
    ap.add_argument("--test", action="store_true",
                    help="send a test record to verify CloudKit auth (development only)")
    ap.add_argument("--test-prod", action="store_true",
                    help="with --test: also write (and delete) the test record in production")
    args = ap.parse_args()

    if args.test:
        # Production is a real public DB with subscribers; a failed delete
        # would leave a __test__ record there, so it is opt-in.
        envs = ENVIRONMENTS if args.test_prod else [e for e in ENVIRONMENTS if e != "production"]
        return test_cloudkit(envs)

    if not (args.ucb or args.all or args.all_if_stale is not None):
        ap.error("pass --ucb, --all, and/or --all-if-stale")

    state = load_state()
    if args.all_if_stale is not None and not args.all:
        args.all = others_stale(state, args.all_if_stale)
        log.info("non-UCB scan %s (stale threshold %.0fh)",
                 "due" if args.all else "skipped", args.all_if_stale)
    alerts: list[dict] = pending_alerts(state)
    if alerts:
        log.info("retrying %d alert(s) left pending by an earlier iteration", len(alerts))
    if args.ucb:
        alerts += diff_and_alert(scan_ucb(), state, per_category=True)
    if args.all:
        alerts += diff_and_alert(scan_others(), state, per_category=False)
    # Send before saving: once the ids are recorded as known they are never
    # re-alerted, so anything CloudKit didn't accept is parked in the state
    # file and retried next iteration (at-least-once).
    unsent = send_alerts(alerts)
    if unsent:
        state[PENDING_KEY] = unsent[-_MAX_PENDING:]
        log.error("%d alert(s) not accepted by CloudKit; parked for retry", len(unsent))
    save_state(state)
    return 1 if unsent else 0


if __name__ == "__main__":
    sys.exit(main())

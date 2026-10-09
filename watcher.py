"""Class-alert watcher: detects newly posted classes and writes CloudKit
records that fan out as push notifications (via each device's
CKQuerySubscriptions — see the app's ClassAlertsStore).

Two modes, run by .github/workflows/class-watch.yml — a self-perpetuating
job that scans UCB roughly every 2 min for ~5.5 h and then dispatches its own
successor, because GitHub delays *scheduled* runs by hours but not running
ones. Three staggered odd-minute crons (class-watch-kick-*.yml) only restart
the chain if it has died.

  --ucb    every iteration: one Arlo catalog pull, split into
           ucb_ny / ucb_la / ucb_online by LOC_* tag or public venue when the
           location tag is missing, categorized by CTG_* tag.
  --all    every non-UCB class source; BCC is categorized like UCB (including
           exclusive core courses), other schools use category "all". The
           chain passes --all-if-stale 20 so this stays a roughly daily scan
           rather than one per iteration.

Each newly detected class becomes ONE record (count 1): it lists every
category that class carries, so a device's single subscription (which matches
any of its picked categories) fires exactly once for it. The title is "New
class at <school>"; the body is the class's name, its instructor and its
category, one line each, every line cut with "…" rather than wrapped. classIDs carries the class's
id in the app's class feed (docs/classes.json: "ucb_ny/43407" for UCB, the
adapter's own id elsewhere) so a tap can open that listing. A school with
more than MAX_INDIVIDUAL_ALERTS new classes in one scan gets one summary
record instead (a new-term drop or an adapter re-id must not become dozens of
pushes).

State (known class ids per school) lives in class-watch.json at the root of
the `class-watch-state` branch — the workflow checks it out into state-branch/
and points WATCH_STATE at it, then commits it back. (The bare default,
state/class-watch.json, is only for local runs.) Each school's entry is
{"ids": [...], "updated": iso} plus "new_at" (iso) once that school has had a
detection: the time new classes were last found there, which the feed
publisher (publish_static.py) compares with the class feed's scraped_at to
refresh that source early. When WATCH_NEW_CLASSES_FILE is set, a run that
detected new classes also appends each such school id to that file after
saving state, so the workflow can dispatch a classes-only feed publish.
A school with NO prior state is baselined silently (no alert flood on the
first run). A scan that comes back EMPTY for a school that had classes is
treated as a failed scan (markup change, transient empty body): its state is
left alone and nothing is alerted, so the next good scan doesn't see every
class as new. Alerts are at-least-once: they are sent before state is saved,
and any that a CloudKit environment failed to accept are parked under
`_pending_alerts` and retried on the next iteration (main() exits non-zero
so the workflow's ::warning fires). CloudKit credentials come from the
environment; missing credentials leave alerts pending rather than consuming
them. Use --dry-run to preview a scan without sending or changing state.

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
import re
import sys
import unicodedata
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
_PENDING_WARN_THRESHOLD = 50      # warn about backlog; never discard undelivered alerts
_MAX_CLOUDKIT_OPERATIONS = 200    # CloudKit Web Services limit per request
MAX_INDIVIDUAL_ALERTS = 5         # more new classes than this at one school → one summary record
NEW_CLASSES_FILE_ENV = "WATCH_NEW_CLASSES_FILE"  # marker: schools with new classes this run
# Push body lines are cut to fit one line, never left to wrap. Widths are SF
# Pro (the iOS system font) at the notification body's 15 pt, measured with
# CoreText for ASCII 32-126; the iOS renderer comes out ~5% narrower. The
# budget is the narrowest body line observed on the smallest current phone
# (iPhone 12/13 mini, 360 pt: ~250-260 pt), less a margin. Larger Dynamic Type
# sizes can still wrap — the server can't know the reader's text size.
_BODY_LINE_BUDGET = 250.0
_ELLIPSIS_WIDTH = 11.84
_NON_ASCII_WIDTH = 12.9  # an "M": wide enough that an unknown glyph never overflows
_GLYPH_WIDTHS = [float(w) for w in (
    "3.98,4.43,6.93,9.21,9.21,13.65,10.44,4.22,5.49,5.49,6.84,9.21,4.22,6.84,4.22,4.34,"
    "9.21,6.72,8.82,9.17,9.42,9.04,9.32,8.31,9.35,9.32,4.22,4.22,9.21,9.21,9.21,7.46,"
    "13.54,9.87,9.62,10.50,10.66,8.70,8.35,10.96,10.90,3.78,7.84,9.65,8.28,12.88,10.90,"
    "11.34,9.29,11.34,9.57,9.32,9.27,10.83,9.87,14.28,9.95,9.59,9.69,5.49,4.34,5.49,9.21,"
    "8.52,7.27,8.04,8.98,8.16,8.98,8.33,5.19,8.91,8.59,3.47,3.46,7.91,3.56,12.82,8.52,"
    "8.63,8.92,8.91,5.48,7.62,5.21,8.52,7.90,11.38,7.63,7.91,7.85,5.49,3.65,5.49,9.21"
).split(",")]
_EXTRA_WIDTHS = {"·": 4.22, "…": _ELLIPSIS_WIDTH, "’": 4.22, "‘": 4.22, "“": 6.93, "”": 6.93,
                 "–": 9.21, "—": 13.65}
_MAX_CLASS_IDS_CHARS = 900        # summary classIDs: whole ids only, comma-joined
# Category keys that describe a format or a missing tag rather than what the
# class teaches — never used as a class's type label.
_NON_TYPE_CATEGORIES = {"workshops", "intensives", "other"}


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
    "improv_core": "Improv Core", "sketch_core": "Sketch Core",
    "sketch": "Sketch",
    "improv": "Improv", "improv_electives": "Improv Electives",
    "sketch_character": "Sketch & Character", "sketch_electives": "Sketch Electives",
    "musical_improv": "Musical Improv", "standup": "Stand-Up",
    "clowning": "Clowning", "acting": "Acting",
    "writing_programs": "Writing Programs", "featured_programs": "Featured Programs",
    "workshops": "Workshops", "intensives": "Intensives", "other": "Other",
}

UCB_LOCATIONS = [("LOC_NY", "ucb_ny"), ("LOC_LA", "ucb_la"), ("LOC_Online", "ucb_online")]
_UCB_SCHOOLS = {school for _, school in UCB_LOCATIONS}
_CORE_LEVELS = {
    "ucb": {"improv": {"101", "201", "301", "401"}, "sketch": {"101", "201", "301"}},
    "brooklyn_cc": {"improv": {"1", "2", "3", "4"}, "sketch": {"1", "2"}},
}
_COURSE_NUMBER_PREFIX = r"^(improv|sketch)(?:\s*:\s*|\s+)(?:level\s+)?([0-9]+)"
_COURSE_LEVEL = re.compile(_COURSE_NUMBER_PREFIX + r"\b", re.I)


def _course_heading(value: str) -> str:
    """Remove listing labels, not prose: BCC seasons and UCB's ONLINE prefix."""
    text = re.sub(r"\s+", " ", value).strip() if isinstance(value, str) else ""
    text = re.sub(r"^(?:\[[^\]]*\]\s*)+", "", text)
    return re.sub(r"^ONLINE\s+", "", text, flags=re.I)


def _core_category(school: str, title: str, level: str = "") -> str | None:
    if school not in _UCB_SCHOOLS and school != "brooklyn_cc":
        return None
    family = "ucb" if school in _UCB_SCHOOLS else school
    allowed = _CORE_LEVELS.get(family)
    if allowed is None:
        return None
    heading = _course_heading(title)
    match = _COURSE_LEVEL.match(heading)
    if match is None:
        # A canonical course label can identify a renamed section, but cannot
        # turn an explicitly musical/advanced class into the ordinary core.
        if (re.match(r"^(?:musical|advanced)\b", heading, re.I)
                or re.match(_COURSE_NUMBER_PREFIX, heading, re.I)):
            return None
        canonical = re.sub(r"^\d+\.\s*", "", _course_heading(level))
        match = _COURSE_LEVEL.match(canonical)
    if match is None:
        return None
    discipline, number = match.group(1).lower(), match.group(2)
    # An explicit unsupported title level never falls back to a different
    # canonical level (Improv 999 with a stale Improv 101 label stays noncore).
    return f"{discipline}_core" if number in allowed[discipline] else None


def class_categories(school: str, title: str, tags=(), level: str = "") -> list[str]:
    """Alert categories, with numbered core courses in exclusive buckets.

    Core never also carries broad genre, Featured, workshop or intensive
    tags: a subscriber who chooses everything except core must not match it
    through another tag. Matching reads titles/canonical labels, never course
    descriptions or prerequisites. A numbered 'Improv 101 Drop-In' is core;
    an unnumbered drop-in keeps its ordinary categories.
    """
    core = _core_category(school, title, level)
    if core:
        return [core]
    if school in _UCB_SCHOOLS:
        return _categories(tags)
    if school == "brooklyn_cc":
        text = f"{title} {level}"
        matched = [key for key in ("improv", "sketch")
                   if re.search(rf"\b{key}\b", text, re.I)]
        return matched or ["other"]
    return ["all"]


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


def _ucb_class_type(canonical: str, tags, categories: list[str]) -> str:
    """The UCB class's type for the push body: Arlo's canonical course name
    (the feed's `level`, numbering stripped the same way), plus the format
    when the name doesn't already say it. Without a canonical name, the label
    of the class's first subject category stands in; format-only or untagged
    classes get no type rather than a meaningless "Other"."""
    kind = re.sub(r"^\d+\.\s*", "", canonical)
    if not kind:
        subject = next((c for c in categories if c not in _NON_TYPE_CATEGORIES), None)
        kind = CATEGORY_LABEL.get(subject, "") if subject else ""
    if not kind:
        return ""
    named = kind.casefold()
    for tag, word in (("FRQ_Workshop", "workshop"), ("FRQ_Intensive", "intensive")):
        if tag in tags and word not in named:
            kind += f" {word}"
    return kind


def scan_ucb() -> dict[str, dict[str, dict]]:
    """Arlo catalog → {school: {EventID: {title, when, categories, feed_id,
    instructor, type}}}. Keys stay bare EventIDs (the watcher state's ids —
    changing them would re-alert every class); `feed_id` is the id the same
    session has in the app's class feed, and `when` its start date."""
    from common import clean
    from sources.ucb_classes import event_location_tags, raw_events

    out: dict[str, dict[str, dict]] = {s: {} for _, s in UCB_LOCATIONS}
    for ev in raw_events():
        tags = ev.get("Tags") or []
        locations = event_location_tags(ev)
        title = clean(ev.get("Name"))
        if not title or not ev.get("EventID"):
            continue
        canonical = next((clean(c.get("Name")) for c in (ev.get("Categories") or [])
                          if isinstance(c, dict)), "")
        # Same names, same order and separator as the class feed's instructor.
        instructor = ", ".join(clean(p.get("Name")) for p in (ev.get("Presenters") or [])
                               if isinstance(p, dict) and p.get("Name"))
        for tag, school in UCB_LOCATIONS:
            if tag in locations:
                when = (ev.get("StartDateTime") or "")[:10]
                categories = class_categories(school, title, tags, canonical)
                out[school][str(ev.get("EventID"))] = {
                    "title": title, "when": when, "categories": categories,
                    "feed_id": f"{school}/{ev.get('EventID')}",
                    "instructor": instructor,
                    "type": _ucb_class_type(canonical, tags, categories),
                }
    return out


def scan_others() -> dict[str, dict[str, dict]]:
    """Every non-UCB class source → class metadata, with categories for BCC.
    The adapter's id is both the state key and the class feed id. Its `level`
    is the class type, except WGIS LA's "Currently Running" bucket, which is a
    status. A source that raises is skipped (state untouched → retried next
    run)."""
    from common import clean
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
        current = {}
        for c in items:
            if not c.get("id"):
                continue
            # clean() tolerates a non-string field, so one odd value can't
            # take down the whole non-UCB scan.
            level = clean(c.get("level"))
            meta = {"title": c.get("title") or "", "when": (c.get("start") or "")[:10],
                    "feed_id": str(c["id"]), "instructor": clean(c.get("instructor")),
                    "type": "" if level.casefold() == "currently running" else level}
            if src["id"] == "brooklyn_cc":
                meta["categories"] = class_categories(src["id"], meta["title"], level=level)
            current[str(c["id"])] = meta
        out[src["id"]] = current
    return out


def others_stale(state: dict, hours: float) -> bool:
    """True when the non-UCB schools haven't been scanned within `hours` — or
    never have. Lets a job that runs every 2 minutes keep the other schools on
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
    """Update state and return alert payloads for genuinely new classes: one
    record per new class, or one summary record for a school with more than
    MAX_INDIVIDUAL_ALERTS of them. UCB (per_category) and BCC records carry
    each class's own categories; other schools use "all".

    A school with new classes gets `new_at` = now in its state entry; a school
    without keeps its earlier `new_at`. Baselines never set it, and the
    empty-scan guard leaves the whole entry untouched."""
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
        if prior.get("new_at"):
            # Carried until the next detection: the feed publisher compares it
            # with the class feed's scraped_at, so dropping it would hide a
            # detection the feed has not caught up with yet.
            state[school]["new_at"] = prior["new_at"]
        known = set(prior.get("ids") or [])
        categorized = per_category or school == "brooklyn_cc"
        new = [meta | {"id": cid,
                       "categories": (meta.get("categories") or ["other"]) if categorized else ["all"]}
               for cid, meta in current.items() if cid not in known]
        if not new:
            continue
        state[school]["new_at"] = now
        for item in new:
            log.info("detected school=%s class_id=%s start=%s title=%r",
                     school, item["id"], item.get("when", ""), item["title"])
        if len(new) > MAX_INDIVIDUAL_ALERTS:
            # Per-class records are right for the usual one or two postings,
            # but a new-term drop or an adapter re-id (every class appearing
            # under a new id) would otherwise turn into dozens of pushes.
            log.warning("%s: %d new classes exceed %d; sending one summary record instead of one per class",
                        school, len(new), MAX_INDIVIDUAL_ALERTS)
            alerts.append(compose_summary(school, new))
        else:
            alerts.extend(compose(school, item) for item in new)
    return alerts


def compose(school: str, item: dict) -> dict:
    """One class's alert payload (count 1). `categories` is every category
    the class carries, so one subscription matching any picked category fires
    once; `category` (its first entry) is the primary, kept for older
    subscribers. classIDs is the class's feed id so the app can open it."""
    name = DISPLAY.get(school, school)
    categories = item["categories"]
    return {
        "school": school, "category": categories[0], "categories": categories,
        "count": 1, "pushTitle": f"New class at {name}", "pushBody": _class_body(item),
        "classIDs": item.get("feed_id") or item["id"],
    }


def compose_summary(school: str, items: list[dict]) -> dict:
    """One record standing in for a flood of new classes at one school. Its
    categories are the union of the classes' (first-seen order) so every
    subscriber who would have heard about any one of them hears this once."""
    name = DISPLAY.get(school, school)
    categories = list(dict.fromkeys(c for i in items for c in i["categories"]))
    return {
        "school": school, "category": categories[0], "categories": categories,
        "count": len(items), "pushTitle": f"{len(items)} new classes at {name}",
        "pushBody": _list_body([i["title"] for i in items]),
        "classIDs": _join_ids([i.get("feed_id") or i["id"] for i in items]),
    }


def _join_ids(ids: list[str], limit: int = _MAX_CLASS_IDS_CHARS) -> str:
    """Comma-join whole ids up to `limit` characters. A cut-off id would
    point the app at a class that doesn't exist, so the list stops before the
    first id that doesn't fit."""
    joined = ""
    for cid in ids:
        candidate = f"{joined},{cid}" if joined else cid
        if len(candidate) > limit:
            break
        joined = candidate
    return joined


def _line_width(text: str) -> float:
    """Approximate rendered width of `text` in the push body font (see
    _GLYPH_WIDTHS). Accented Latin letters measure as their base letter."""
    total = 0.0
    for ch in text:
        code = ord(ch)
        if 32 <= code <= 126:
            total += _GLYPH_WIDTHS[code - 32]
        elif ch in _EXTRA_WIDTHS:
            total += _EXTRA_WIDTHS[ch]
        else:
            base = unicodedata.normalize("NFKD", ch)[:1]
            total += (_GLYPH_WIDTHS[ord(base) - 32] if base and 32 <= ord(base) <= 126
                      else _NON_ASCII_WIDTH)
    return total


def _fit_line(text: str, budget: float = _BODY_LINE_BUDGET) -> str:
    """One body line, cut with "…" where it would wrap. Whitespace (a newline
    inside a source title included) collapses first, so a value can never
    spill onto a second line on its own."""
    text = " ".join(text.split())
    if _line_width(text) <= budget:
        return text
    room = budget - _ELLIPSIS_WIDTH
    cut, used = 0, 0.0
    for i, ch in enumerate(text):
        used += _line_width(ch)
        if used > room:
            break
        cut = i + 1
    return text[:cut].rstrip() + "…"


def _class_body(item: dict) -> str:
    """The class's name, its instructor, then its category — one line each,
    every line cut to fit rather than wrapped, missing ones left out. The
    title is "New class at <school>". A collapsed banner shows two body lines
    (name and instructor); the Lock Screen and Notification Center show all
    three. The category is dropped when it only repeats the class name."""
    title = item.get("title") or ""
    kind = item.get("type") or ""
    lines = [title, item.get("instructor") or "",
             kind if kind.casefold() != title.casefold() else ""]
    return "\n".join(_fit_line(line) for line in lines if line.strip())


def _list_body(titles: list[str]) -> str:
    """A summary record's body: the first three class names, one fitted line
    each, then "and N more"."""
    shown = [_fit_line(t) for t in titles[:3] if t.strip()]
    more = len(titles) - min(len(titles), 3)
    if more > 0:
        shown.append(f"and {more} more")
    return "\n".join(shown)


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
    environments = list(dict.fromkeys(ENVIRONMENTS))
    if not environments:
        log.error("no CloudKit environments configured; keeping %d alert(s) pending", len(alerts))
        return alerts

    batch = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    unsent: dict[int, list[str]] = {}   # alert index → environments still owed
    for i, a in enumerate(alerts):
        # Temporarily narrowing CLOUDKIT_ENVS must not erase an earlier
        # obligation. Those environments have not acknowledged anything and
        # remain pending until a later run enables them again.
        deferred = list(dict.fromkeys(env for env in (a.get("envs") or []) if env not in environments))
        if deferred:
            unsent[i] = deferred
            log.warning("keeping alert pending for unconfigured environment(s): %s", ",".join(deferred))
    for env in environments:
        env_targets = [(i, a) for i, a in enumerate(alerts) if env in (a.get("envs") or environments)]
        if not env_targets:
            continue
        if not _key_id(env) or not PRIVATE_KEY_PEM:
            log.error("%s: CloudKit credentials missing; keeping %d alert(s) pending", env, len(env_targets))
            for i, _ in env_targets:
                unsent.setdefault(i, []).append(env)
            continue
        subpath = f"/database/1/{CONTAINER}/{env}/public/records/modify"
        # A long outage can leave more alerts than CloudKit accepts in one
        # request. Drain bounded batches, preserving failures per environment
        # without blocking the later batches (including newly found classes).
        for start in range(0, len(env_targets), _MAX_CLOUDKIT_OPERATIONS):
            targets = env_targets[start:start + _MAX_CLOUDKIT_OPERATIONS]
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
                records = result.get("records") if isinstance(result, dict) else None
                if not isinstance(records, list):
                    raise ValueError("CloudKit response has no records acknowledgement list")
                # A 200 response is not an acknowledgement of every write. Match
                # each requested name exactly once; omitted, malformed, duplicate,
                # or failed entries remain pending instead of silently losing them.
                accepted = 0
                for name, i in names.items():
                    matches = [r for r in records if isinstance(r, dict) and r.get("recordName") == name]
                    if len(matches) != 1 or matches[0].get("serverErrorCode"):
                        reason = (matches[0].get("serverErrorCode") if len(matches) == 1
                                  else "missing or duplicate record acknowledgement")
                        log.warning("%s: record %s not accepted: %s", env, name, reason)
                        unsent.setdefault(i, []).append(env)
                        continue
                    accepted += 1
                    a = alerts[i]
                    log.info("%s: accepted %s school=%s categories=%s", env, name,
                             a["school"], "+".join(a["categories"]))
                log.info("%s: wrote %d alert record(s), %d unacknowledged or failed", env,
                         accepted, len(targets) - accepted)
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


def mark_new_classes(fresh: list[dict]) -> None:
    """Append each school that had newly detected classes this run to the
    WATCH_NEW_CLASSES_FILE marker, one id per line, so the workflow can
    publish the class feed now instead of on its daily cadence (the push
    otherwise names a class the Classes tab doesn't show yet). Called after
    save_state, whether or not CloudKit accepted the alerts: the feed refresh
    is independent of push delivery. Pending-alert retries are not passed in,
    so they never trigger a publish. A marker failure costs only the early
    refresh — the next publish still sees `new_at` — so it warns and never
    fails the run."""
    path = os.environ.get(NEW_CLASSES_FILE_ENV)
    schools = list(dict.fromkeys(a["school"] for a in fresh))
    if not path or not schools:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.writelines(f"{school}\n" for school in schools)
    except OSError as e:
        log.warning("could not append new-class schools %s to %s: %r", ",".join(schools), path, e)
        return
    log.info("marked new classes for feed refresh: %s", ",".join(schools))


def main() -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    ap = argparse.ArgumentParser()
    ap.add_argument("--ucb", action="store_true", help="scan UCB (NY/LA/Online) via Arlo")
    ap.add_argument("--all", action="store_true", help="scan every non-UCB class source")
    ap.add_argument("--all-if-stale", type=float, metavar="HOURS",
                    help="scan the non-UCB sources only if their state is older than HOURS")
    ap.add_argument("--dry-run", action="store_true",
                    help="preview alerts without CloudKit writes or state changes")
    ap.add_argument("--test", action="store_true",
                    help="send a test record to verify CloudKit auth (development only)")
    ap.add_argument("--test-prod", action="store_true",
                    help="with --test: also write (and delete) the test record in production")
    args = ap.parse_args()

    if args.dry_run and args.test:
        ap.error("--dry-run cannot be combined with --test (which writes a probe record)")
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
    fresh: list[dict] = []   # this run's detections only, never retried ones
    scan_failed = False
    if args.ucb:
        try:
            scanned = scan_ucb()
        except Exception as e:  # noqa: BLE001 — still deliver previously parked alerts
            log.error("UCB scan failed; keeping prior school state: %r", e)
            scan_failed = True
        else:
            fresh += diff_and_alert(scanned, state, per_category=True)
    if args.all:
        fresh += diff_and_alert(scan_others(), state, per_category=False)
    alerts += fresh
    if args.dry_run:
        log.info("DRY RUN: %d alert(s); no CloudKit writes or state changes", len(alerts))
        for a in alerts:
            log.info("  [%s/%s] %s — %s", a["school"], "+".join(a["categories"]),
                     a["pushTitle"], a["pushBody"])
        return 1 if scan_failed else 0
    # Send before saving: once the ids are recorded as known they are never
    # re-alerted, so anything CloudKit didn't accept is parked in the state
    # file and retried next iteration (at-least-once).
    unsent = send_alerts(alerts)
    if unsent:
        state[PENDING_KEY] = unsent
        log.error("%d alert(s) not accepted by CloudKit; parked for retry", len(unsent))
        if len(unsent) > _PENDING_WARN_THRESHOLD:
            log.warning("alert backlog exceeds %d; retaining all %d undelivered alert(s)",
                        _PENDING_WARN_THRESHOLD, len(unsent))
    save_state(state)
    mark_new_classes(fresh)
    return 1 if unsent or scan_failed else 0


if __name__ == "__main__":
    sys.exit(main())

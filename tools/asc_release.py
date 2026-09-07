"""App Store Connect release steps from the CLI — what the web UI calls
"create version / What's New / App Review notes / select build / Submit".

Uses the same key setup as asc_pass_cert.py (ASC_ISSUER_ID, ASC_KEY_ID,
ASC_KEY_PATH; Admin or App Manager role). Run from the repo root with the
project venv (needs `cryptography`):

    .venv/bin/python tools/asc_release.py discover com.salimhafid.UCBShows
    .venv/bin/python tools/asc_release.py create-version <appId> 1.6
    .venv/bin/python tools/asc_release.py whatsnew <versionId> whatsnew.txt
    .venv/bin/python tools/asc_release.py review <versionId> notes.txt
    .venv/bin/python tools/asc_release.py attach <versionId> <buildId>
    .venv/bin/python tools/asc_release.py submit <appId> <versionId>

Creating a version copies the previous version's localization (description,
keywords, URLs, screenshots) and review contact, but NOT What's New or the
promotional text — set both. `submit` is irreversible.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_pass_cert import call  # noqa: E402


def discover(bundle_id: str) -> None:
    for a in call("GET", f"/apps?filter[bundleId]={bundle_id}")["data"]:
        print("app:", a["id"], a["attributes"]["name"], a["attributes"]["bundleId"])
        for v in call("GET", f"/apps/{a['id']}/appStoreVersions?limit=10")["data"]:
            at = v["attributes"]
            print("  version:", v["id"], at["versionString"], at.get("appVersionState"), at.get("createdDate"))
        for b in call("GET", f"/builds?filter[app]={a['id']}&sort=-uploadedDate&limit=5")["data"]:
            at = b["attributes"]
            print("  build:", b["id"], "no.", at["version"], at["processingState"], at.get("uploadedDate"),
                  "nonExemptEncryption", at.get("usesNonExemptEncryption"))


def create_version(app_id: str, version: str) -> None:
    out = call("POST", "/appStoreVersions", {"data": {"type": "appStoreVersions",
        "attributes": {"platform": "IOS", "versionString": version, "releaseType": "AFTER_APPROVAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
    print("created version:", out["id"], out["attributes"]["versionString"], out["attributes"].get("appVersionState"))


def whatsnew(version_id: str, path: str, promo: str | None = None) -> None:
    text = open(path).read().strip()
    attrs = {"whatsNew": text}
    if promo:
        attrs["promotionalText"] = promo
    locs = call("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    if not locs:
        raise SystemExit("no localization on this version — create it in ASC first (copies from the last version)")
    for loc in locs:
        out = call("PATCH", f"/appStoreVersionLocalizations/{loc['id']}",
                   {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
        print("whatsNew set on", loc["attributes"]["locale"], "chars:", len(out["data"]["attributes"].get("whatsNew") or ""))


def review(version_id: str, notes_path: str) -> None:
    notes = open(notes_path).read().strip()
    det = call("GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail")["data"]
    out = call("PATCH", f"/appStoreReviewDetails/{det['id']}",
               {"data": {"type": "appStoreReviewDetails", "id": det["id"],
                         "attributes": {"notes": notes, "demoAccountRequired": False}}})["data"]["attributes"]
    print("review notes set; contact:", out.get("contactFirstName"), out.get("contactLastName"), out.get("contactEmail"))


def attach(version_id: str, build_id: str) -> None:
    call("PATCH", f"/appStoreVersions/{version_id}/relationships/build", {"data": {"type": "builds", "id": build_id}})
    b = call("GET", f"/appStoreVersions/{version_id}/build")["data"]
    print("attached build:", b["id"], "no.", b["attributes"]["version"], b["attributes"]["processingState"])


def submit(app_id: str, version_id: str) -> None:
    open_ = call("GET", f"/reviewSubmissions?filter[app]={app_id}&filter[state]=READY_FOR_REVIEW")["data"]
    if open_:
        rs = open_[0]
        print("reusing open submission", rs["id"])
    else:
        rs = call("POST", "/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
        print("created submission", rs["id"])
    if not call("GET", f"/reviewSubmissions/{rs['id']}/items")["data"]:
        call("POST", "/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems",
            "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rs["id"]}},
                              "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
    done = call("PATCH", f"/reviewSubmissions/{rs['id']}",
                {"data": {"type": "reviewSubmissions", "id": rs["id"], "attributes": {"submitted": True}}})["data"]
    print("submitted:", done["id"], done["attributes"].get("state"), done["attributes"].get("submittedDate"))


if __name__ == "__main__":
    cmd, *rest = sys.argv[1:] or ["help"]
    cmds = {"discover": discover, "create-version": create_version, "whatsnew": whatsnew,
            "review": review, "attach": attach, "submit": submit}
    if cmd not in cmds:
        raise SystemExit(__doc__)
    cmds[cmd](*rest)

"""Minimal App Store Connect API client for issuing the Wallet pass-signing certificate.

Needs an ASC API key with the Admin role (Developer-role keys get 403 on certificate
creation). Requires the `cryptography` package (in requirements.txt).

Env: ASC_ISSUER_ID, ASC_KEY_ID, ASC_KEY_PATH (.p8). Team keys use `iss`.
Usage:
  asc_api.py whoami                      # lists pass type ids + PASS_TYPE_ID certs (auth probe)
  asc_api.py create-pass-type <id> <name>
  asc_api.py create-cert <passTypeId-resource-id> <csr.pem> <out_cert.pem>
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

API = "https://api.appstoreconnect.apple.com/v1"


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token() -> str:
    issuer, kid, path = os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_ID"], os.environ["ASC_KEY_PATH"]
    key = serialization.load_pem_private_key(open(path, "rb").read(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{_b64(json.dumps(header).encode())}.{_b64(json.dumps(payload).encode())}".encode()
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input.decode() + "." + _b64(sig)


def call(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp) if resp.status != 204 else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code} {method} {path}: {e.read().decode()[:800]}")


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "whoami"
    if cmd == "whoami":
        ptids = call("GET", "/passTypeIds?limit=50")
        print("passTypeIds:", [(p["id"], p["attributes"]["identifier"], p["attributes"]["name"]) for p in ptids.get("data", [])])
        certs = call("GET", "/certificates?filter[certificateType]=PASS_TYPE_ID&limit=50")
        print("PASS_TYPE_ID certs:", [(c["id"], c["attributes"].get("name"), c["attributes"].get("expirationDate"), c["attributes"].get("serialNumber")) for c in certs.get("data", [])])
        return 0
    if cmd == "create-pass-type":
        ident, name = argv[2], argv[3]
        out = call("POST", "/passTypeIds", {"data": {"type": "passTypeIds", "attributes": {"identifier": ident, "name": name}}})
        print(json.dumps(out["data"], indent=1))
        return 0
    if cmd == "create-cert":
        ptid, csr_path, out_path = argv[2], argv[3], argv[4]
        csr = open(csr_path).read()
        out = call("POST", "/certificates", {"data": {
            "type": "certificates",
            "attributes": {"certificateType": "PASS_TYPE_ID", "csrContent": csr},
            "relationships": {"passTypeId": {"data": {"type": "passTypeIds", "id": ptid}}},
        }})
        attrs = out["data"]["attributes"]
        der = base64.b64decode(attrs["certificateContent"])
        pem = "-----BEGIN CERTIFICATE-----\n" + "\n".join(
            base64.b64encode(der).decode()[i:i + 64] for i in range(0, len(base64.b64encode(der).decode()), 64)) + "\n-----END CERTIFICATE-----\n"
        with open(out_path, "w") as f:
            f.write(pem)
        print("certificate:", out["data"]["id"], attrs.get("name"), attrs.get("serialNumber"), "expires", attrs.get("expirationDate"))
        print("wrote", out_path)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

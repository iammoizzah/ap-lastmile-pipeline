"""
Pushes downloaded SROIE receipts through the running API (upload -> extract ->
match -> route) so the review queue has realistic content, and prints a summary.

Needs the API running:  uvicorn app.main:app --reload

Usage:
    cd backend
    python3 scripts/batch_ingest.py --n 40
"""
import argparse
import collections
import glob
import os

import requests

RECEIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data", "receipts"))


def main(n: int, url: str):
    paths = sorted(glob.glob(os.path.join(RECEIPTS_DIR, "*.jpg")))[:n]
    if not paths:
        raise SystemExit(f"No receipts in {RECEIPTS_DIR}. Run download_sroie.py first.")

    routes, flags, errors = collections.Counter(), collections.Counter(), []
    for i, path in enumerate(paths, 1):
        with open(path, "rb") as f:
            r = requests.post(f"{url}/invoices/upload", files={"file": (os.path.basename(path), f, "image/jpeg")})
        if r.status_code != 200:
            errors.append((os.path.basename(path), r.status_code, r.text[:120]))
            continue
        body = r.json()
        routes[body["route"]] += 1
        for fl in body["matching"]["flags"]:
            flags[fl["code"]] += 1
        print(f"[{i}/{len(paths)}] {os.path.basename(path)} -> route={body['route']} "
              f"risk={body['risk_score']} flags={[x['code'] for x in body['matching']['flags']]}")

    ok = len(paths) - len(errors)
    print(f"\nIngested {ok}/{len(paths)} receipts")
    print("Routes:", dict(routes))
    print("Flags: ", dict(flags.most_common()))
    for name, code, text in errors:
        print(f"  ERROR {name}: {code} {text}")
    print(f"\nReview queue: {url}/review/queue")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--n", type=int, default=40)
    p.add_argument("--url", default="http://localhost:8000")
    a = p.parse_args()
    main(a.n, a.url)

"""
Pipeline evaluation: how well does the WHOLE system (extraction + PO matching +
routing) protect the business, measured against SROIE ground truth?

It uploads receipts through the running API, then scores each result:
  * correct   = extracted vendor AND total both match the ground truth
  * the route the system chose (fast_track vs full review)

The headline comparison is against the naive alternative, "trust the extractor
when its own confidence is high". The gap between the two is the value of
cross-checking against a second source (vendor master + purchase orders).

IMPORTANT CAVEAT, print it in any write-up: the purchase orders in this demo
are generated from the same ground truth (scripts/seed_po_from_sroie.py), so
the PO check has an easier job here than against a real ERP. Treat the numbers
as a demonstration of the mechanism, not a prediction of production accuracy.

Needs the API running and an EMPTY invoices table (re-uploading the same
receipts would make them all look like duplicates).

Usage:
    cd backend
    python3 scripts/eval_pipeline.py --n 100
"""
import argparse
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

RECEIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data", "receipts"))
BASELINE_CONFIDENCE = 0.85  # same bar the system uses for fast-track


def norm_amount(value):
    try:
        return round(float(re.sub(r"[^\d.]", "", str(value))), 2)
    except (ValueError, TypeError):
        return None


def vendor_matches(extracted, truth) -> bool:
    from app.services.matching import name_similarity
    return bool(extracted and truth) and name_similarity(extracted, truth) >= 0.85


def run_eval(client, base_url: str, paths: list, require_empty: bool = True) -> list:
    """Upload each receipt through the API and score it against its ground truth.
    `client` needs .get/.post like requests.Session (a FastAPI TestClient works too)."""
    if require_empty:
        existing = client.get(f"{base_url}/invoices").json()
        if existing:
            raise SystemExit(
                f"The invoices table already has {len(existing)} rows. Clear it first so duplicates "
                "from earlier runs don't distort the numbers:\n  docker exec -it ap_pipeline_db psql "
                "-U ap_user -d ap_pipeline -c \"TRUNCATE review_decisions, expected_payments, "
                "invoices, audit_log CASCADE;\"\n(or pass --force)")

    records = []
    for i, path in enumerate(paths, 1):
        truth = (json.load(open(path[:-4] + ".json")).get("entities")) or {}
        with open(path, "rb") as f:
            r = client.post(f"{base_url}/invoices/upload",
                            files={"file": (os.path.basename(path), f, "image/jpeg")})
        if r.status_code != 200:
            print(f"  skipped {os.path.basename(path)}: HTTP {r.status_code}")
            continue
        body = r.json()
        got_vendor = body["extracted"]["company"]["value"]
        got_total = body["extracted"]["total"]["value"]
        vendor_ok = vendor_matches(got_vendor, truth.get("company"))
        total_ok = (norm_amount(got_total) is not None
                    and norm_amount(got_total) == norm_amount(truth.get("total")))
        records.append({
            "key": os.path.splitext(os.path.basename(path))[0],
            "route": body["route"],
            "flags": [f["code"] for f in body["matching"]["flags"]],
            "ext_conf": body["overall_confidence"],
            "risk": body["risk_score"],
            "vendor_ok": vendor_ok,
            "total_ok": total_ok,
            "correct": vendor_ok and total_ok,
        })
        if i % 10 == 0:
            print(f"  processed {i}/{len(paths)}")
    return records


def score(records: list, baseline_conf: float = BASELINE_CONFIDENCE) -> dict:
    n = len(records)
    wrong = [r for r in records if not r["correct"]]
    fast = [r for r in records if r["route"] == "fast_track"]
    review = [r for r in records if r["route"] == "review"]
    fast_wrong = [r for r in fast if not r["correct"]]
    review_wrong = [r for r in review if not r["correct"]]
    review_fine = [r for r in review if r["correct"]]
    base_pass = [r for r in records if r["ext_conf"] >= baseline_conf]
    base_wrong = [r for r in base_pass if not r["correct"]]

    def pct(a, b):
        return round(100 * a / b, 1) if b else None

    flag_counts = {}
    for r in records:
        for code in r["flags"]:
            flag_counts[code] = flag_counts.get(code, 0) + 1

    return {
        "n": n,
        "fully_correct": n - len(wrong),
        "fully_correct_pct": pct(n - len(wrong), n),
        "wrong_total": len(wrong),
        "system": {
            "fast_tracked": len(fast),
            "fast_tracked_wrong": len(fast_wrong),
            "fast_track_precision_pct": pct(len(fast) - len(fast_wrong), len(fast)),
            "sent_to_review": len(review),
            "review_actually_wrong": len(review_wrong),
            "review_false_alarms": len(review_fine),
            "wrong_caught_pct": pct(len(wrong) - len(fast_wrong), len(wrong)),
            "wrong_escaped": len(fast_wrong),
        },
        "confidence_only_baseline": {
            "threshold": baseline_conf,
            "would_skip_review": len(base_pass),
            "of_those_wrong": len(base_wrong),
            "wrong_caught_pct": pct(len(wrong) - len(base_wrong), len(wrong)),
            "wrong_escaped": len(base_wrong),
        },
        "flag_counts": dict(sorted(flag_counts.items(), key=lambda kv: -kv[1])),
    }


def print_report(s: dict):
    sy, bl = s["system"], s["confidence_only_baseline"]
    print(f"\n=== Pipeline evaluation over {s['n']} real SROIE receipts ===")
    print(f"\nExtraction alone: vendor AND total both correct on {s['fully_correct']}/{s['n']} "
          f"({s['fully_correct_pct']}%). {s['wrong_total']} invoices have a wrong vendor or total.")
    print("\nWith PO cross-check and routing (this system):")
    print(f"  fast-tracked:            {sy['fast_tracked']}  "
          f"(wrong among them: {sy['fast_tracked_wrong']}, precision {sy['fast_track_precision_pct']}%)")
    print(f"  sent to human review:    {sy['sent_to_review']}  "
          f"({sy['review_actually_wrong']} really wrong, {sy['review_false_alarms']} false alarms)")
    print(f"  wrong invoices caught:   {sy['wrong_caught_pct']}%  ({sy['wrong_escaped']} escaped to fast-track)")
    print(f"\nBaseline, trusting extraction confidence >= {bl['threshold']} alone:")
    print(f"  would skip review:       {bl['would_skip_review']}  (wrong among them: {bl['of_those_wrong']})")
    print(f"  wrong invoices caught:   {bl['wrong_caught_pct']}%  ({bl['wrong_escaped']} escaped)")
    print("\nFlags raised:", s["flag_counts"])
    print("\nCaveat: purchase orders here are generated from the same ground truth, so the PO "
          "check is easier than it would be against a real ERP.")


def main(n: int, url: str, force: bool):
    import requests
    paths = sorted(glob.glob(os.path.join(RECEIPTS_DIR, "*.jpg")))[:n]
    if not paths:
        raise SystemExit(f"No receipts in {RECEIPTS_DIR}. Run download_sroie.py first.")
    print(f"Uploading {len(paths)} receipts to {url} ...")
    records = run_eval(requests.Session(), url, paths, require_empty=not force)
    result = score(records)
    print_report(result)
    out = os.path.join(os.path.dirname(RECEIPTS_DIR), "pipeline_eval_report.json")
    with open(out, "w") as f:
        json.dump({"summary": result, "records": records}, f, indent=2)
    print(f"\nFull report: {out}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--n", type=int, default=100)
    p.add_argument("--url", default="http://localhost:8000")
    p.add_argument("--force", action="store_true", help="skip the empty-table check")
    a = p.parse_args()
    main(a.n, a.url, a.force)

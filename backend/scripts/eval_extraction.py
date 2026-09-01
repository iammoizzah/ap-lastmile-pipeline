
"""
Runs the extraction service against every downloaded SROIE receipt and
scores it against the real ground truth (company/date/total) — giving you
an actual, citable accuracy number for the case study instead of a guess.

Usage:
    cd backend
    python scripts/eval_extraction.py
"""
import sys
import os
import json
import re
import glob
from datetime import datetime

sys.path.insert(0, os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..")))

RECEIPTS_DIR = os.path.join(os.path.dirname(
    __file__), "..", "data", "receipts")


def normalize_text(s: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", s.upper()) if s else ""


def normalize_amount(s: str):
    try:
        return round(float(str(s).replace(",", "").replace("RM", "").strip()), 2)
    except (ValueError, TypeError):
        return None


DATE_FORMATS = [
    "%d/%m/%Y", "%d-%m-%Y", "%Y-%m-%d", "%d/%m/%y", "%d-%m-%y",
    "%d %b %Y", "%d %B %Y",
]


def normalize_date(s: str):
    if not s:
        return None
    s = s.strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            continue
    return s.upper()  # fall back to raw comparison if unparseable


def company_match(extracted: str, truth: str) -> bool:
    if not extracted or not truth:
        return False
    e, t = normalize_text(extracted), normalize_text(truth)
    return e in t or t in e  # substring match — receipts often extract a partial name


def main():
    # imported here, not at module top,
    from app.services.extraction import extract_from_image
    # so editor auto-sort can't move it

    image_paths = sorted(glob.glob(os.path.join(RECEIPTS_DIR, "*.jpg")))
    if not image_paths:
        print(
            f"No receipts found in {RECEIPTS_DIR}. Run scripts/download_sroie.py first.")
        return

    total = len(image_paths)
    correct = {"company": 0, "date": 0, "total": 0}
    field_attempted = {"company": 0, "date": 0, "total": 0}
    confidences = []
    rows = []

    skipped = []
    for img_path in image_paths:
        key = os.path.splitext(os.path.basename(img_path))[0]
        gt_path = os.path.join(RECEIPTS_DIR, f"{key}.json")
        if not os.path.exists(gt_path):
            skipped.append((key, "no ground-truth json"))
            continue

        gt_raw = json.load(open(gt_path))
        gt = gt_raw.get("entities")
        if not gt:
            skipped.append((key, "no 'entities' key (stale/old-format file)"))
            continue

        result = extract_from_image(img_path)
        confidences.append(result.overall_confidence)

        c_ok = company_match(result.company.value, gt.get("company"))
        d_ok = normalize_date(
            result.date.value) == normalize_date(gt.get("date"))
        t_ok = normalize_amount(
            result.total.value) == normalize_amount(gt.get("total"))

        for field_name, ok, extracted in [
            ("company", c_ok, result.company.value),
            ("date", d_ok, result.date.value),
            ("total", t_ok, result.total.value),
        ]:
            if extracted is not None:
                field_attempted[field_name] += 1
            if ok:
                correct[field_name] += 1

        rows.append({
            "key": key,
            "company_ok": c_ok, "date_ok": d_ok, "total_ok": t_ok,
            "confidence": result.overall_confidence,
        })

    print(f"\n=== Extraction accuracy over {total} real SROIE receipts ===\n")
    if skipped:
        print(f"\nSkipped {len(skipped)} file(s):")
        for key, reason in skipped:
            print(f"  {key}: {reason}")
    for f in ["company", "date", "total"]:
        acc = correct[f] / total * 100
        precision = (correct[f] / field_attempted[f] *
                     100) if field_attempted[f] else 0
        print(f"  {f:10s}  accuracy: {acc:5.1f}%   "
              f"(precision when attempted: {precision:5.1f}%, "
              f"attempted {field_attempted[f]}/{total})")

    overall = sum(correct.values()) / (total * 3) * 100
    avg_conf = sum(confidences) / len(confidences) if confidences else 0
    print(f"\n  Overall field accuracy: {overall:.1f}%")
    print(f"  Average confidence score: {avg_conf:.2f}")

    # Confidence calibration check: are low-confidence extractions actually
    # more often wrong? This is the number that matters most for the HITL
    # story — it justifies routing low-confidence items to human review.
    low_conf_rows = [r for r in rows if r["confidence"] < 0.7]
    if low_conf_rows:
        low_conf_wrong = sum(
            1 for r in low_conf_rows if not (r["company_ok"] and r["date_ok"] and r["total_ok"])
        )
        print(
            f"\n  Low-confidence (<0.7) receipts: {len(low_conf_rows)}/{total}")
        print(f"  Of those, fully-wrong-somewhere: {low_conf_wrong}/{len(low_conf_rows)} "
              f"({low_conf_wrong/len(low_conf_rows)*100:.0f}%) — this is the routing signal HITL relies on")

    out_path = os.path.join(os.path.dirname(__file__),
                            "..", "data", "extraction_eval_report.json")
    with open(out_path, "w") as f:
        json.dump({"total": total, "correct": correct, "field_attempted": field_attempted,
                   "overall_accuracy_pct": overall, "avg_confidence": avg_conf, "rows": rows}, f, indent=2, default=str)
    print(f"\nFull report saved to {out_path}")


if __name__ == "__main__":
    main()

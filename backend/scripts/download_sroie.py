"""
Downloads a sample of the SROIE dataset (ICDAR 2019 Robust Reading
Challenge — 973 real scanned receipts with ground-truth company/date/total
annotations) from its Hugging Face mirror, for use as realistic test input
to the invoice extraction pipeline.

Source: https://huggingface.co/datasets/rth/sroie-2019-v2
(mirrors the original ICDAR 2019 SROIE competition data)

Requires: pip install datasets  (already in requirements.txt)

Usage:
    cd backend
    python scripts/download_sroie.py --n 25

Output:
    backend/data/receipts/<id>.jpg
    backend/data/receipts/<id>.json   (ground truth: company, date, total, address)
"""
import argparse
import json
import os

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "receipts")


def main(n: int):
    try:
        from datasets import load_dataset
    except ImportError:
        raise SystemExit(
            "Missing dependency. Run: pip install datasets"
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Loading SROIE sample from Hugging Face (rth/sroie-2019-v2), n={n} ...")
    ds = load_dataset("rth/sroie-2019-v2", split=f"train[:{n}]")

    saved = 0
    for i, row in enumerate(ds):
        try:
            image = row["image"]
            gt_raw = row.get("text", row.get("ground_truth", None))

            img_path = os.path.join(OUT_DIR, f"receipt_{i:04d}.jpg")
            image.convert("RGB").save(img_path)

            gt_path = os.path.join(OUT_DIR, f"receipt_{i:04d}.json")
            with open(gt_path, "w") as f:
                if isinstance(gt_raw, str):
                    try:
                        parsed = json.loads(gt_raw)
                    except json.JSONDecodeError:
                        parsed = {"raw": gt_raw}
                else:
                    parsed = gt_raw or {}
                json.dump(parsed, f, indent=2)

            saved += 1
        except Exception as e:
            print(f"  skipped row {i}: {e}")

    print(f"Saved {saved} receipt images + ground-truth files to {OUT_DIR}")
    print("Note: field names in ground truth vary slightly across dataset "
          "revisions — inspect one .json file before wiring up the extraction "
          "accuracy check in Milestone 2.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=25, help="number of receipts to download")
    args = parser.parse_args()
    main(args.n)


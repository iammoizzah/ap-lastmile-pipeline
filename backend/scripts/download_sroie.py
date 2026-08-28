"""
Downloads a sample of the SROIE dataset (ICDAR 2019 Robust Reading
Challenge — real scanned receipts with ground-truth key-info annotations:
company, date, address, total) from its Hugging Face mirror, for use as
realistic test input to the invoice extraction pipeline.

Source: https://huggingface.co/datasets/jsdnrs/ICDAR2019-SROIE
(corrected/extended version of the original ICDAR 2019 SROIE Task 3 data;
confirmed schema: image, key, image_size, entities{company,date,address,total},
words, bboxes)

Requires: pip install datasets  (already in requirements.txt)

Usage:
    cd backend
    python scripts/download_sroie.py --n 25

Output:
    backend/data/receipts/<key>.jpg
    backend/data/receipts/<key>.json   (ground truth: company, date, total,
                                         address, plus raw OCR words/bboxes
                                         for later line-level matching)
"""
import argparse
import json
import os

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "receipts")


def main(n: int, split: str):
    try:
        from datasets import load_dataset
    except ImportError:
        raise SystemExit(
            "Missing dependency. Run: python3 -m pip install -r requirements.txt"
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Loading SROIE sample from Hugging Face (jsdnrs/ICDAR2019-SROIE), "
          f"split={split}, n={n} ...")
    ds = load_dataset("jsdnrs/ICDAR2019-SROIE", split=f"{split}[:{n}]")

    saved = 0
    for row in ds:
        try:
            key = row["key"]
            image = row["image"]

            img_path = os.path.join(OUT_DIR, f"{key}.jpg")
            image.convert("RGB").save(img_path)

            gt_path = os.path.join(OUT_DIR, f"{key}.json")
            ground_truth = {
                "key": key,
                "entities": row.get("entities", {}),
                "words": row.get("words", []),
                "bboxes": row.get("bboxes", []),
            }
            with open(gt_path, "w") as f:
                json.dump(ground_truth, f, indent=2)

            saved += 1
        except Exception as e:
            print(f"  skipped {row.get('key', '?')}: {e}")

    print(f"Saved {saved} receipt images + ground-truth files to {OUT_DIR}")
    if saved:
        sample_key = json.load(open(os.path.join(OUT_DIR, f"{ds[0]['key']}.json")))
        print("Sample entities from first receipt:", sample_key["entities"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=25, help="number of receipts to download")
    parser.add_argument("--split", type=str, default="test", choices=["train", "test"],
                         help="which SROIE split to pull from (default: test, 361 receipts)")
    args = parser.parse_args()
    main(args.n, args.split)


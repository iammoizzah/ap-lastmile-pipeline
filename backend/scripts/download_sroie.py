"""
Downloads SROIE receipts (ICDAR 2019: real scanned receipts with ground-truth company,
date, address and total) from Hugging Face (jsdnrs/ICDAR2019-SROIE).

Usage:
    cd backend
    python3 scripts/download_sroie.py --n 25                              # first 25 of the test split
    python3 scripts/download_sroie.py --split train --n 100               # first 100 of train
    python3 scripts/download_sroie.py --split train --start 100 --n 100 --out data/receipts_fresh
                                                                          # a NEW batch nobody has seen

Output (per receipt):  <out>/<key>.jpg  and  <out>/<key>.json  (entities, words, bboxes)
"""
import argparse
import json
import os

DEFAULT_OUT = os.path.join(os.path.dirname(__file__), "..", "data", "receipts")


def main(n: int, split: str, start: int, out: str):
    try:
        from datasets import load_dataset
    except ImportError:
        raise SystemExit("Missing dependency. Run: python3 -m pip install -r requirements.txt")

    out = os.path.abspath(out)
    os.makedirs(out, exist_ok=True)
    print(f"Loading SROIE from Hugging Face (jsdnrs/ICDAR2019-SROIE), split={split}, "
          f"rows {start} to {start + n - 1} ...")
    ds = load_dataset("jsdnrs/ICDAR2019-SROIE", split=f"{split}[{start}:{start + n}]")

    saved = 0
    for row in ds:
        try:
            key = row["key"]
            row["image"].convert("RGB").save(os.path.join(out, f"{key}.jpg"))
            with open(os.path.join(out, f"{key}.json"), "w") as f:
                json.dump({"key": key, "entities": row.get("entities", {}),
                           "words": row.get("words", []), "bboxes": row.get("bboxes", [])}, f, indent=2)
            saved += 1
        except Exception as e:
            print(f"  skipped {row.get('key', '?')}: {e}")

    print(f"Saved {saved} receipts to {out}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--n", type=int, default=25, help="how many receipts")
    p.add_argument("--split", default="test", choices=["train", "test"])
    p.add_argument("--start", type=int, default=0, help="row offset within the split")
    p.add_argument("--out", default=DEFAULT_OUT, help="output folder")
    a = p.parse_args()
    main(a.n, a.split, a.start, a.out)

"""
Measures which OCR strategy actually works on your receipts. For every receipt it runs
each variant in app/services/ocr.py, runs the normal field extraction on the text, and
scores company / date / total against the SROIE ground truth.

It also simulates "adaptive retry" (try variants in order, stop when company, date and
total have all been found) from the same cached runs, and reports how many OCR passes
that costs on average. Finally it prints real failure samples for the best strategy, so
parser problems can be told apart from OCR problems.

Use a DEVELOPMENT set for this (it is how we choose a strategy). Never use the same
receipts for the final number.

Usage:
    cd backend
    python3 scripts/ocr_experiment.py --n 60
    python3 scripts/ocr_experiment.py --dir data/receipts_fresh --n 100
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import re
import sys
from datetime import datetime

os.environ.setdefault("OMP_THREAD_LIMIT", "1")  # one thread per Tesseract process; we parallelise across receipts
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FIELDS = ("company", "date", "total")


def worker(path):
    from app.services.extraction import extract_fields
    from app.services.ocr import VARIANTS, ocr
    out = {}
    for name in VARIANTS:
        try:
            text = ocr(path, name)
        except Exception as e:  # keep going; record the failure
            text = ""
            print(f"  OCR error on {os.path.basename(path)} [{name}]: {e}")
        ex = extract_fields(text)
        out[name] = {"company": ex.company.value, "date": ex.date.value, "total": ex.total.value, "text": text}
    return path, out


# ---- scoring (same rules as eval_extraction.py) ----
def amount(s):
    try:
        return round(float(re.sub(r"[^\d.]", "", str(s))), 2)
    except (ValueError, TypeError):
        return None


DATE_FORMATS = ["%d/%m/%Y", "%d-%m-%Y", "%Y-%m-%d", "%d/%m/%y", "%d-%m-%y", "%d %b %Y", "%d %B %Y", "%d %b %y"]


def norm_date(s):
    if not s:
        return None
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(s.strip(), fmt).date()
        except ValueError:
            pass
    return s.strip().upper()


def company_ok(extracted, truth):
    legal = re.compile(r"\b(SDN|BHD|S/B|LTD|LLC|INC|CORP|CORPORATION|CO|PLC|PTE|LIMITED)\b")
    core = lambda s: re.sub(r"[^A-Z0-9]", "", legal.sub(" ", s.upper()))
    if not extracted or not truth:
        return False
    e, t = core(extracted), core(truth)
    return len(e) >= 3 and len(t) >= 3 and (e in t or t in e)


def correct(res, truth):
    return {
        "company": company_ok(res["company"], truth.get("company")),
        "date": res["date"] is not None and norm_date(res["date"]) == norm_date(truth.get("date")),
        "total": amount(res["total"]) is not None and amount(res["total"]) == amount(truth.get("total")),
    }


def found(res):
    return sum(res[f] is not None for f in FIELDS)


def choose(per_variant, order):
    """Adaptive retry: first variant that finds all three fields, else the one that found most."""
    for i, name in enumerate(order):
        if found(per_variant[name]) == 3:
            return name, i + 1
    best = max(range(len(order)), key=lambda i: (found(per_variant[order[i]]), -i))
    return order[best], len(order)


def main(directory, n, workers):
    paths = sorted(glob.glob(os.path.join(directory, "*.jpg")))[:n]
    if not paths:
        raise SystemExit(f"No receipts in {directory}")
    print(f"Running 7 OCR variants on {len(paths)} receipts with {workers} workers ...")
    runs, done = {}, 0
    with cf.ProcessPoolExecutor(max_workers=workers) as pool:
        for path, out in pool.map(worker, paths):
            runs[path] = out
            done += 1
            if done % 10 == 0:
                print(f"  {done}/{len(paths)}")
    truth = {p: (json.load(open(p[:-4] + ".json")).get("entities") or {}) for p in paths}
    from app.services.ocr import VARIANTS

    def score(choose_fn):
        c = {f: 0 for f in FIELDS}
        allfound = passes = 0
        for p in paths:
            name, used = choose_fn(runs[p], truth[p])
            r = runs[p][name]
            ok = correct(r, truth[p])
            for f in FIELDS:
                c[f] += ok[f]
            allfound += found(r) == 3
            passes += used
        n_ = len(paths)
        return c, allfound, passes / n_

    def row(label, c, allfound, avg_passes):
        n_ = len(paths)
        s = sum(c.values()) / (3 * n_) * 100
        print(f"{label:34s}{100*c['company']/n_:8.0f}%{100*c['date']/n_:6.0f}%{100*c['total']/n_:7.0f}%"
              f"{s:9.1f}%{100*allfound/n_:8.0f}%{avg_passes:8.1f}")

    print(f"\nAccuracy against ground truth on {len(paths)} receipts")
    print(f"{'strategy':34s}{'company':>9s}{'date':>7s}{'total':>8s}{'overall':>10s}{'all 3 found':>12s}{'passes':>8s}")
    singles = {}
    for name in VARIANTS:
        singles[name] = score(lambda per, t, name=name: (name, 1))
        row(f"single: {name}", *singles[name])
    orders = {
        "adaptive: up_psm6 > up_min > otsu": ["up_psm6", "up_min_psm6", "otsu_psm6"],
        "adaptive: raw > up_psm6 > up_min": ["raw", "up_psm6", "up_min_psm6"],
        "adaptive: all variants": list(VARIANTS),
    }
    for label, order in orders.items():
        row(label, *score(lambda per, t, order=order: choose(per, order)))
    oracle = score(lambda per, t: (max(per, key=lambda nme: sum(correct(per[nme], t).values())), len(per)))
    row("ceiling (peeks at truth, unusable)", *oracle)
    print("\npasses = average OCR runs per receipt. 'all 3 found' = company, date and total all returned something.")

    empty = {name: sum(1 for p in paths if not runs[p][name]["text"].strip()) for name in VARIANTS}
    print("Receipts where OCR returned no text at all:", empty)

    # failure samples for the best single variant
    best = max(singles, key=lambda k: sum(singles[k][0].values()))
    print(f"\n=== Failure samples for the best single variant ({best}) ===")
    shown = {"date": 0, "company": 0}
    loose_date = re.compile(r"DATE|TARIKH|\d{1,2}\s*[/.\-]\s*\d{1,2}\s*[/.\-]\s*\d{2,4}", re.I)
    for p in paths:
        r, t = runs[p][best], truth[p]
        ok = correct(r, t)
        lines = [l.strip() for l in r["text"].splitlines() if l.strip()]
        if not ok["date"] and t.get("date") and shown["date"] < 6:
            shown["date"] += 1
            print(f"\n[date] {os.path.basename(p)}  truth={t['date']!r}  extracted={r['date']!r}")
            for l in [l for l in lines if loose_date.search(l)][:3] or ["(no line looks like a date)"]:
                print("    OCR:", l[:80])
        if not ok["company"] and t.get("company") and shown["company"] < 6:
            shown["company"] += 1
            print(f"\n[company] {os.path.basename(p)}  truth={t['company']!r}  extracted={r['company']!r}")
            for l in lines[:4]:
                print("    OCR:", l[:80])

    out = os.path.join(ROOT, "data", "ocr_experiment.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump({os.path.basename(p): runs[p] for p in paths}, open(out, "w"))
    print(f"\nRaw results saved to {out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=os.path.join(ROOT, "data", "receipts"))
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--workers", type=int, default=min(6, os.cpu_count() or 2))
    a = ap.parse_args()
    main(a.dir, a.n, a.workers)

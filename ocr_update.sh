#!/usr/bin/env bash
# OCR tooling update. Run from the REPO ROOT (the folder containing backend/).
# Adds: app/services/ocr.py, scripts/ocr_experiment.py, scripts/ocr_debug.py, tests/test_ocr.py
# Replaces: scripts/download_sroie.py (adds --start/--out), scripts/apply_fixes.py (adds a v3 fix),
#           tests/test_extraction_fixes.py. Does NOT touch extraction.py: apply_fixes.py does that, with checks.
set -e
if [ ! -d backend/app ]; then echo "Run this from the repo root (folder containing backend/)."; exit 1; fi

mkdir -p "$(dirname "backend/app/services/ocr.py")"
cat > "backend/app/services/ocr.py" << 'OCR_EOF'
"""
OCR strategies for receipts. Tesseract's default call is tuned for clean document
scans; SROIE-style receipts are small, noisy and sometimes printed in colour, so we
keep several named variants (preprocessing + page-segmentation mode) and choose
between them with data (scripts/ocr_experiment.py), not by guesswork.

  raw           exactly what the app did before: default Tesseract on the untouched image
  raw_psm6      untouched image, "single uniform block of text" mode
  up_psm6       greyscale, upscaled to ~1500px wide, contrast-stretched, sharpened, psm 6
  up_psm4       same preprocessing, "single column" mode
  up_min_psm6   as up_psm6 but greyscale = darkest colour channel, so pink/red print stays dark
  otsu_psm6     as up_psm6, then hard black-and-white threshold (Otsu)
  up_psm11      as up_psm6, "sparse text" mode (finds scattered fragments)
"""
from typing import Callable, Dict, Optional, Tuple

import pytesseract
from PIL import Image, ImageChops, ImageFilter, ImageOps

TARGET_WIDTH = 1500   # Tesseract reads small print poorly; scale small receipts up to about this width
MAX_SCALE = 4.0


def _upscale(img: Image.Image) -> Image.Image:
    scale = min(max(TARGET_WIDTH / img.width, 1.0), MAX_SCALE)
    if scale < 1.05:
        return img
    return img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)


def _gray(img: Image.Image) -> Image.Image:
    return ImageOps.grayscale(img)


def _darkest_channel(img: Image.Image) -> Image.Image:
    r, g, b = img.split()
    return ImageChops.darker(ImageChops.darker(r, g), b)


def _enhance(g: Image.Image) -> Image.Image:
    return ImageOps.autocontrast(g, cutoff=1).filter(ImageFilter.SHARPEN)


def otsu_threshold(g: Image.Image) -> int:
    """Threshold that best separates dark text from light paper (Otsu's method)."""
    hist = g.histogram()
    total = sum(hist)
    sum_all = sum(i * h for i, h in enumerate(hist))
    w_b = sum_b = 0
    best_var, best_t = -1.0, 127
    for t in range(256):
        w_b += hist[t]
        if w_b == 0:
            continue
        w_f = total - w_b
        if w_f == 0:
            break
        sum_b += t * hist[t]
        m_b, m_f = sum_b / w_b, (sum_all - sum_b) / w_f
        var = w_b * w_f * (m_b - m_f) ** 2
        if var > best_var:
            best_var, best_t = var, t
    return best_t


def _binarize(g: Image.Image) -> Image.Image:
    t = otsu_threshold(g)
    return g.point(lambda p: 255 if p > t else 0)


Prep = Callable[[Image.Image], Image.Image]
VARIANTS: Dict[str, Tuple[Prep, Optional[int]]] = {
    "raw": (lambda im: im, None),
    "raw_psm6": (lambda im: im, 6),
    "up_psm6": (lambda im: _enhance(_gray(_upscale(im))), 6),
    "up_psm4": (lambda im: _enhance(_gray(_upscale(im))), 4),
    "up_min_psm6": (lambda im: _enhance(_darkest_channel(_upscale(im))), 6),
    "otsu_psm6": (lambda im: _binarize(_enhance(_gray(_upscale(im)))), 6),
    "up_psm11": (lambda im: _enhance(_gray(_upscale(im))), 11),
}


def ocr(image_path: str, variant: str, timeout: int = 60) -> str:
    """Run one named OCR variant on an image file and return the raw text."""
    prep, psm = VARIANTS[variant]
    img = Image.open(image_path)
    if variant != "raw":  # "raw" must stay byte-for-byte what the app did before
        img = ImageOps.exif_transpose(img).convert("RGB")
    config = f"--psm {psm}" if psm else ""
    return pytesseract.image_to_string(prep(img), config=config, timeout=timeout)
OCR_EOF

mkdir -p "$(dirname "backend/scripts/ocr_experiment.py")"
cat > "backend/scripts/ocr_experiment.py" << 'OCR_EOF'
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
OCR_EOF

mkdir -p "$(dirname "backend/scripts/ocr_debug.py")"
cat > "backend/scripts/ocr_debug.py" << 'OCR_EOF'
"""
Shows what each OCR variant makes of ONE image, to diagnose a receipt the system
read badly (for example the one showing "Vendor not found" with 0% confidence).

Usage:
    cd backend
    python3 scripts/ocr_debug.py path/to/image.jpg
"""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


def main(path):
    from PIL import Image
    from app.services.extraction import extract_fields
    from app.services.ocr import VARIANTS, ocr

    im = Image.open(path)
    print(f"{path}\n  size={im.size} mode={im.mode} format={im.format} exif_orientation={im.getexif().get(274)}")
    for name in VARIANTS:
        text = ocr(path, name)
        ex = extract_fields(text)
        lines = [l for l in text.splitlines() if l.strip()]
        print(f"\n--- {name}: {len(lines)} lines | company={ex.company.value!r} date={ex.date.value!r} total={ex.total.value!r}")
        for l in lines[:6]:
            print("    ", l[:78])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 scripts/ocr_debug.py <image path>")
    main(sys.argv[1])
OCR_EOF

mkdir -p "$(dirname "backend/scripts/download_sroie.py")"
cat > "backend/scripts/download_sroie.py" << 'OCR_EOF'
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
OCR_EOF

mkdir -p "$(dirname "backend/scripts/apply_fixes.py")"
cat > "backend/scripts/apply_fixes.py" << 'OCR_EOF'
#!/usr/bin/env python3
"""
One-off patch for two files you have edited locally:

  app/services/extraction.py
    * extract_total   -> tiered logic: CASH-line confirmation, tax-line exclusion,
                         multi-number summary rows deprioritised
    * extract_company -> rejects addresses, "TAX INVOICE" banners and bare "SDN BHD"
  scripts/eval_extraction.py
    * company_match   -> stops crediting "SDN BHD" as a correct company name

How it stays safe:
  * Functions are located by parsing the file (ast), so editor reformatting doesn't matter.
  * The patched code is executed against real receipt-shaped examples BEFORE anything is
    written. If any check fails, nothing is changed.
  * Originals are saved next to the files as *.bak.
  * Safe to run twice: already-patched files are skipped.

Usage (from anywhere):
    python3 backend/scripts/apply_fixes.py
"""
import ast
import os
import shutil
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
EXTRACTION = os.path.join(HERE, "..", "app", "services", "extraction.py")
EVAL = os.path.join(HERE, "eval_extraction.py")

MARK_TOTAL = "[patch v2: tiered total extraction]"
MARK_COMPANY = "[patch v2: company sanity filters]"
MARK_EVAL = "[patch v2: company matcher ignores legal suffixes]"
MARK_ADDR = "[patch v3: business names may contain place words]"

TOTAL_BLOCK = '''# ''' + MARK_TOTAL + '''
CASH_LINE = re.compile(r"^\\s*CASH\\b", re.IGNORECASE)


def extract_total(lines: list[str]) -> FieldResult:
    candidates = []  # (index, line, [money values as float])
    for i, line in enumerate(lines):
        if not TOTAL_KEYWORDS.search(line):
            continue
        has_gst = re.search(r"GST", line, re.IGNORECASE)
        has_tax = re.search(r"\\bTAX\\b", line, re.IGNORECASE)
        has_rate = re.search(r"\\d+(?:\\.\\d+)?\\s*%", line)
        has_incl = re.search(r"INCL|NETT|NET\\b", line, re.IGNORECASE)
        if (has_gst or has_tax) and (has_rate or not has_incl):
            continue  # tax-rate line or unlabeled tax/GST line, not the invoice total

        values = []
        for m in MONEY_PATTERN.findall(line):
            try:
                values.append(float(m.replace(",", "")))
            except ValueError:
                pass
        candidates.append((i, line, values))

    # Tier 1: a single-value candidate immediately followed by a "CASH ..." line with the
    # SAME amount. The strongest signal: this is the amount that actually changed hands,
    # not a subtotal, a tax line, or a duplicate summary row further down.
    for i, line, values in candidates:
        if len(values) == 1 and i + 1 < len(lines) and CASH_LINE.search(lines[i + 1]):
            cash_vals = MONEY_PATTERN.findall(lines[i + 1])
            if cash_vals and abs(float(cash_vals[0].replace(",", "")) - values[0]) < 0.01:
                return FieldResult(
                    f"{values[0]:.2f}", 0.95,
                    f"'{line.strip()}' amount matches following CASH line (high-confidence signal)")

    # Tier 2: the LAST single-value candidate. A line with exactly one number is more likely
    # a clean total than a multi-number breakdown row, and receipts list tax before the total.
    single_value = [(i, line, v) for i, line, v in candidates if len(v) == 1]
    if single_value:
        i, line, values = single_value[-1]
        return FieldResult(f"{values[0]:.2f}", 0.9, f"matched keyword line: {line.strip()!r}")

    # Tier 3: keyword line with no money on it; the amount sometimes lands on the next OCR line.
    for i, line, values in reversed(candidates):
        if not values and i + 1 < len(lines):
            next_vals = MONEY_PATTERN.findall(lines[i + 1])
            if next_vals:
                return FieldResult(
                    next_vals[-1].replace(",", ""), 0.75,
                    f"matched keyword line {line.strip()!r}, amount on following line: "
                    f"{lines[i + 1].strip()!r}")

    # Tier 4: only multi-number breakdown rows matched. Low confidence on purpose.
    if candidates:
        i, line, values = candidates[-1]
        if values:
            return FieldResult(
                f"{values[-1]:.2f}", 0.55,
                f"low-confidence: only a multi-value breakdown row matched: {line.strip()!r}")

    # Fallback: largest money value anywhere on the receipt.
    all_amounts = []
    for line in lines:
        for m in MONEY_PATTERN.findall(line):
            try:
                all_amounts.append(float(m.replace(",", "")))
            except ValueError:
                continue
    if all_amounts:
        return FieldResult(f"{max(all_amounts):.2f}", 0.5,
                           "fallback: largest money value on receipt (no TOTAL keyword found)")

    return FieldResult(None, 0.0, "no money values found")
'''

COMPANY_BLOCK = '''# ''' + MARK_COMPANY + '''
_C_NOISE = re.compile(
    r"COPY|RECEIPT|INVOICE|CASH\\s*SALE|CASH\\s*BILL|DUPLICATE|ORIGINAL", re.IGNORECASE)
_C_ADDRESS = re.compile(
    r"\\b(JALAN|JLN|LORONG|LOT|TAMAN|BANDAR|KAWASAN|BLOK|BLOCK|LEVEL|FLOOR|TEL|FAX|PHONE|"
    r"GST|ROC|EMAIL|WWW)\\b|\\bNO\\.?\\s*\\d|@|\\b\\d{5}\\b", re.IGNORECASE)
_C_LEGAL = re.compile(r"\\b(SDN\\.?\\s*BHD\\.?|S/B|BHD|LTD|LLC|INC|CORP|CORPORATION|PLC)\\b",
                      re.IGNORECASE)
_C_HINT = re.compile(
    r"\\b(SDN\\.?\\s*BHD|S/B|BHD|ENTERPRISES?|TRADING|SERVICES?|STORE|MARKET|MART|SHOP|SUPPLIES|"
    r"RESTAURANT|CAFE|HARDWARE|INDUSTRIES|CORPORATION|CORP|LTD|LLC|INC|PHARMACY|STATIONERY|"
    r"GROCER|KOPITIAM)\\b", re.IGNORECASE)


def _company_plausible(line: str) -> bool:
    s = line.strip()
    if len(re.sub(r"[^A-Za-z]", "", s)) < 4:
        return False
    if _C_NOISE.search(s) or _C_ADDRESS.search(s):
        return False
    # must contain a real name once legal suffixes ("SDN BHD") are removed
    return len(re.sub(r"[^A-Za-z]", "", _C_LEGAL.sub(" ", s))) >= 3


def extract_company(lines: list[str]) -> FieldResult:
    candidates = [l for l in lines[:10] if _company_plausible(l)]

    # Pass 1: a plausible line that also looks like a business name
    for line in candidates:
        if _C_HINT.search(line):
            return FieldResult(line.strip(), 0.8, f"matched company-suffix pattern: {line.strip()!r}")

    # Pass 2: fallback, the first plausible all-caps line near the top
    for line in candidates:
        letters = re.sub(r"[^A-Za-z]", "", line)
        if len(letters) >= 5 and letters.isupper():
            return FieldResult(line.strip(), 0.4, "fallback: first substantial uppercase line near top")

    return FieldResult(None, 0.0, "no plausible company line found in top of receipt")
'''


ADDR_BLOCK = '''# ''' + MARK_ADDR + '''
_C_CONTACT = re.compile(
    r"\\b(TEL|FAX|PHONE|GST|ROC|EMAIL|WWW)\\b|\\bNO\\.?\\s*\\d|@|\\b\\d{5}\\b", re.IGNORECASE)
_C_PLACE = re.compile(
    r"\\b(JALAN|JLN|LORONG|LOT|TAMAN|BANDAR|KAWASAN|BLOK|BLOCK|LEVEL|FLOOR)\\b", re.IGNORECASE)


def _company_plausible(line: str) -> bool:
    s = line.strip()
    if len(re.sub(r"[^A-Za-z]", "", s)) < 4:
        return False
    if _C_NOISE.search(s) or _C_CONTACT.search(s):
        return False
    # Place words (TAMAN, JALAN, LOT ...) mark an address line, unless the line also looks
    # like a business name: "BOOK TA .K (TAMAN DAYA) SDN BHD" is a company, "NO 12 JALAN BESAR" is not.
    if _C_PLACE.search(s) and not _C_HINT.search(s):
        return False
    return len(re.sub(r"[^A-Za-z]", "", _C_LEGAL.sub(" ", s))) >= 3
'''

EVAL_BLOCK = '''# ''' + MARK_EVAL + '''
def company_match(extracted, truth) -> bool:
    legal = re.compile(r"\\b(SDN|BHD|S/B|LTD|LLC|INC|CORP|CORPORATION|CO|PLC|PTE|LIMITED)\\b")

    def core(s):
        return re.sub(r"[^A-Z0-9]", "", legal.sub(" ", s.upper()))

    if not extracted or not truth:
        return False
    e, t = core(extracted), core(truth)
    if len(e) < 3 or len(t) < 3:  # "SDN BHD" alone must not count as a company name
        return False
    return e in t or t in e  # substring match: receipts often yield a partial name
'''


def replace_function(source: str, name: str, new_block: str) -> str:
    tree = ast.parse(source)
    node = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name), None)
    if node is None:
        raise SystemExit(f"Could not find a top-level function named {name!r}.")
    start = (node.decorator_list[0].lineno if node.decorator_list else node.lineno) - 1
    lines = source.splitlines(keepends=True)
    return "".join(lines[:start]) + new_block.rstrip("\n") + "\n" + "".join(lines[node.end_lineno:])


def load_module(source: str, name: str) -> types.ModuleType:
    mod = types.ModuleType(name)
    mod.__file__ = name
    exec(compile(source, name, "exec"), mod.__dict__)
    return mod


# --- self-checks: realistic receipt text, with the answers we expect ---------------
def check_extraction(mod) -> list:
    fail = []

    def total(text):
        return mod.extract_fields(text).total.value

    def company(text):
        return mod.extract_fields(text).company.value

    t = total("SUB-TOTAL (EX) : 25.80\nTOTAL TAX : 4.85\nROUNDING : 0.00\nTOTAL : 27.35\n"
              "CASH : 27.35\nCHANGE : 0.00\nTAX CODE AMOUNT TAX\nTOTAL: 25.80 1.55")
    if t != "27.35":
        fail.append(f"CASH-confirmed total: expected 27.35, got {t}")
    t = total("TakeOut Total (incl GST) 38.90\nTotal Rounded 38.90\nCash Tendered 50.00\n"
              "Change 11.10\nTOTAL INCLUDES 6% GST 2.20")
    if t != "38.90":
        fail.append(f"GST-rate line must not win: expected 38.90, got {t}")
    t = total("Total GST @6%: 0.00\nTotal Inclusive GST: 193.00")
    if t != "193.00":
        fail.append(f"inclusive total: expected 193.00, got {t}")
    t = total("(Excluded GST) Sub Total (RM) 411.50\nTotal GST (RM) 24.89\nTotal (RM): 436.20")
    if t != "436.20":
        fail.append(f"tax line must not win: expected 436.20, got {t}")
    t = total("Total RM inc.GST:\n4.90")
    if t != "4.90":
        fail.append(f"amount on next line: expected 4.90, got {t}")

    c = company("TAN CHAY YEE\n*** COPY ***\nOJC MARKETING SDN BHD\nROC NO: 538358-H")
    if c != "OJC MARKETING SDN BHD":
        fail.append(f"company: expected OJC MARKETING SDN BHD, got {c!r}")
    c = company("ART TAX INVOICE\nSDN BHD\n47, JALAN MERANTI 1, SEK. 3,\n44300 BATANG KALI")
    if c is not None:
        fail.append(f"banner/suffix/address must not become the company, got {c!r}")
    c = company("99 SPEED MART S/B (519537-X)\nLOT 12 JALAN BESAR")
    if c != "99 SPEED MART S/B (519537-X)":
        fail.append(f"company starting with digits: got {c!r}")
    c = company("BOOK TA .K (TAMAN DAYA) SDN BHD\nNO.53 55,57 & 59, JALAN SAGU 18, TAMAN DAYA,\n81100 JOHOR BAHRU")
    if c != "BOOK TA .K (TAMAN DAYA) SDN BHD":
        fail.append(f"company containing a place word: got {c!r}")
    c = company("UROKO JAPANESE CUISINE SDN BHD\nNO. 5 JALAN SATU")
    if c != "UROKO JAPANESE CUISINE SDN BHD":
        fail.append(f"company: got {c!r}")
    return fail


def check_eval(ns) -> list:
    cm, fail = ns["company_match"], []
    if cm("SDN BHD", "OJC MARKETING SDN BHD"):
        fail.append("bare 'SDN BHD' must not match a real company")
    if not cm("OJC MARKETING", "OJC MARKETING SDN BHD"):
        fail.append("partial name should match")
    if not cm("OJC MARKETING SDN BHD", "OJC MARKETING SDN. BHD."):
        fail.append("punctuation differences should match")
    return fail


def backup(path: str):
    bak = path + ".bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)


def main():
    changed = []

    # --- extraction.py ---
    path = os.path.abspath(EXTRACTION)
    src = open(path).read()
    new = src
    if MARK_TOTAL not in new:
        new = replace_function(new, "extract_total", TOTAL_BLOCK)
    if MARK_COMPANY not in new:
        new = replace_function(new, "extract_company", COMPANY_BLOCK)
    if MARK_ADDR not in new:
        new = replace_function(new, "_company_plausible", ADDR_BLOCK)
    if new == src:
        print("extraction.py: already patched, skipping.")
    else:
        ast.parse(new)
        failures = check_extraction(load_module(new, "extraction_candidate"))
        if failures:
            print("extraction.py: self-checks FAILED, nothing was changed:")
            for f in failures:
                print("  -", f)
            sys.exit(1)
        backup(path)
        open(path, "w").write(new)
        changed.append("app/services/extraction.py")

    # --- eval_extraction.py ---
    path = os.path.abspath(EVAL)
    src = open(path).read()
    if MARK_EVAL in src:
        print("eval_extraction.py: already patched, skipping.")
    else:
        new = replace_function(src, "company_match", EVAL_BLOCK)
        ast.parse(new)
        ns = {"re": __import__("re")}
        exec(compile(EVAL_BLOCK, "eval_block", "exec"), ns)
        failures = check_eval(ns)
        if failures:
            print("eval_extraction.py: self-checks FAILED, nothing was changed:")
            for f in failures:
                print("  -", f)
            sys.exit(1)
        backup(path)
        open(path, "w").write(new)
        changed.append("scripts/eval_extraction.py")

    if changed:
        print("Patched and self-checked:", ", ".join(changed))
        print("Originals saved as *.bak next to each file.")
    print("Next: python3 scripts/eval_extraction.py")


if __name__ == "__main__":
    main()
OCR_EOF

mkdir -p "$(dirname "backend/tests/test_ocr.py")"
cat > "backend/tests/test_ocr.py" << 'OCR_EOF'
"""Tests for the OCR strategies. The OCR-running tests are skipped if Tesseract isn't installed."""
import shutil

import pytest
from PIL import Image, ImageDraw, ImageFont

from app.services import ocr as ocr_mod

needs_tesseract = pytest.mark.skipif(shutil.which("tesseract") is None, reason="tesseract not installed")


def test_variants_include_the_untouched_baseline_and_all_psm_modes():
    assert {"raw", "raw_psm6", "up_psm6", "up_psm4", "up_min_psm6", "otsu_psm6", "up_psm11"} <= set(ocr_mod.VARIANTS)
    assert ocr_mod.VARIANTS["raw"][1] is None  # default Tesseract call, as before


def test_otsu_separates_dark_text_from_light_paper():
    img = Image.new("L", (100, 100), 235)
    ImageDraw.Draw(img).rectangle((10, 10, 60, 60), fill=30)
    t = ocr_mod.otsu_threshold(img)
    assert 30 <= t < 235
    out = ocr_mod._binarize(img)
    assert out.getpixel((20, 20)) == 0 and out.getpixel((90, 90)) == 255


def test_upscale_only_grows_small_images_and_caps_the_scale():
    small = Image.new("RGB", (400, 800), "white")
    assert ocr_mod._upscale(small).width == 1500
    already_big = Image.new("RGB", (1600, 800), "white")
    assert ocr_mod._upscale(already_big).size == (1600, 800)
    tiny = Image.new("RGB", (100, 100), "white")
    assert ocr_mod._upscale(tiny).width == 400  # capped at 4x


def test_darkest_channel_keeps_pink_print_dark():
    pink = Image.new("RGB", (4, 4), (220, 60, 140))
    assert ocr_mod._darkest_channel(pink).getpixel((0, 0)) == 60
    assert ocr_mod._gray(pink).getpixel((0, 0)) > 100  # plain greyscale washes it out


@needs_tesseract
def test_ocr_reads_a_clean_generated_receipt_with_every_variant(tmp_path):
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 22) \
        if shutil.os.path.exists("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf") else ImageFont.load_default()
    img = Image.new("RGB", (640, 160), "white")
    d = ImageDraw.Draw(img)
    d.text((20, 20), "ACME TRADING SDN BHD", font=font, fill="black")
    d.text((20, 70), "TOTAL 123.45", font=font, fill="black")
    path = tmp_path / "r.png"
    img.save(path)
    for name in ["raw", "up_psm6", "up_min_psm6", "otsu_psm6"]:
        text = ocr_mod.ocr(str(path), name)
        assert "123.45" in text, f"{name} lost the total: {text!r}"
OCR_EOF

mkdir -p "$(dirname "backend/tests/test_extraction_fixes.py")"
cat > "backend/tests/test_extraction_fixes.py" << 'OCR_EOF'
"""
Regression tests for extraction fixes, using receipt-shaped text taken from real
SROIE failures. These run against the real parser (not a stub), so they fail if
scripts/apply_fixes.py has not been run yet. That is intended.
"""
import pytest

from app.services.extraction import extract_fields


def total_of(text):
    return extract_fields(text).total


def company_of(text):
    return extract_fields(text).company.value


# Receipts have a correct "TOTAL : x" line followed by "CASH : x", and a duplicate
# tax-summary row at the bottom ("TOTAL: subtotal tax") that used to win.
@pytest.mark.parametrize("text,expected", [
    ("SUB-TOTAL (BX) : 25.80\nTOTAL TAX : 4.85\nROUNDING : 0.00\nTOTAL : 27.35\n"
     "CASH : 27.35\nCHANGE ; 0.00\nTOTAL: 25.80 1.55", "27.35"),
    ("Total Qty.: 8 120.00\nSUB-TOTAL (EX) : 120.00\nTOTAL TAX 7.20\nROUNDING : 0.00\n"
     "TOTAL : 127.20\nCASH : 127.20\nCHANGE : 0.00\nTOTAL; 120.00 7.20", "127.20"),
    ("Total Qty. : 2 1.00\nSUB-TOTAL (EX) : 1.00\nTOTAL TAX : 0.06\nROUNDING : -0.01\n"
     "TOTAL : 1.05\nCASH 1.05\nCHANGE 0.00\nTOTAL: 1.00 0.06", "1.05"),
])
def test_total_confirmed_by_matching_cash_line(text, expected):
    t = total_of(text)
    assert t.value == expected
    assert t.confidence >= 0.95


def test_gst_amount_line_with_rate_is_not_the_total():
    t = total_of("TakeOut Total (incl GST) 38.90\nTotal Rounded 38.90\nCash Tendered 50.00\n"
                 "Change 11.10\nTOTAL INCLUDES 6% GST 2.20")
    assert t.value == "38.90"


def test_tax_only_lines_are_skipped_in_favour_of_the_real_total():
    assert total_of("Total GST @6%: 0.00\nTotal Inclusive GST: 193.00").value == "193.00"
    assert total_of("(Excluded GST) Sub Total (RM) 411.50\nTotal GST (RM) 24.89\n"
                    "Total (RM): 436.20").value == "436.20"


def test_amount_on_the_line_after_the_label():
    assert total_of("Total RM inc.GST:\n4.90").value == "4.90"


def test_garbled_receipt_falls_back_with_low_confidence():
    t = total_of("KO13 180\n23.03\n1296652800\n0.94\n0.06")
    assert t.confidence <= 0.5  # the system must admit it is guessing


def test_company_skips_copy_banner_and_cashier_name():
    assert company_of("TAN CHAY YEE\n*** COPY ***\nOJC MARKETING SDN BHD\nROC NO: 538358-H") \
        == "OJC MARKETING SDN BHD"


def test_company_rejects_banners_bare_suffixes_and_addresses():
    # real failures from the first 40-receipt run: vendor came out as these lines
    assert company_of("ART TAX INVOICE\nSDN BHD\n47, JALAN MERANTI 1, SEK. 3,\n44300 BATANG KALI") is None
    assert company_of("* TAX INVOICE *\nNO. 53, JALAN BESAR,\n+60 3 1234 5678") is None


def test_company_names_that_start_with_digits_still_work():
    assert company_of("99 SPEED MART S/B (519537-X)\nLOT 12 JALAN BESAR") == "99 SPEED MART S/B (519537-X)"


def test_clean_receipt_end_to_end():
    r = extract_fields("OJC MARKETING SDN BHD\nDATE : 15/01/2019 11:05:16 AM\nTotal Inclusive GST: 193.00")
    assert (r.company.value, r.date.value, r.total.value) == ("OJC MARKETING SDN BHD", "15/01/2019", "193.00")
    assert r.overall_confidence >= 0.85


def test_company_name_containing_a_place_word_is_still_a_company():
    # real SROIE receipt: "TAMAN" is part of the branch name, not an address line
    text = "BOOK TA .K (TAMAN DAYA) SDN BHD\nNO.53 55,57 & 59, JALAN SAGU 18, TAMAN DAYA,\n81100 JOHOR BAHRU"
    assert company_of(text) == "BOOK TA .K (TAMAN DAYA) SDN BHD"
OCR_EOF

# pytesseract/Pillow are already in requirements.txt; nothing to add.
echo "Written. Next: python3 backend/scripts/apply_fixes.py"

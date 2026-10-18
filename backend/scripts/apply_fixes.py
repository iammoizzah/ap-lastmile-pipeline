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

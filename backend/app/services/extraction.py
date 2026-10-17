"""
Extraction service: turns a receipt/invoice image into structured fields
(company, date, total) with a confidence score and a stated reason for
each field — not just a black-box number. This is deliberately rule-based
rather than an LLM call: it's boring, cheap, fast, fully explainable, and
gives us a real accuracy baseline to compare an optional LLM path against
later (see extraction_method="llm" on the Invoice model for that hook).

Design note for the case study: routing on confidence, not on "is this
right", is the actual product decision here. A human reviewer should see
*why* something is uncertain (which field, which heuristic failed) rather
than just a float.
"""
import re
from datetime import datetime
from dataclasses import dataclass, field
from typing import Optional

try:
    import pytesseract
    from PIL import Image
except ImportError:
    pytesseract = None
    Image = None


# --- OCR -----------------------------------------------------------------

def run_ocr(image_path: str) -> str:
    """Runs Tesseract OCR on an image file, returns raw text."""
    if pytesseract is None:
        raise RuntimeError(
            "pytesseract/Pillow not installed. Run: python3 -m pip install -r requirements.txt"
        )
    image = Image.open(image_path)
    return pytesseract.image_to_string(image)


# --- Field parsers ---------------------------------------------------------

TOTAL_KEYWORDS = re.compile(
    r"(GRAND\s*TOTAL|TOTAL\s*AMOUNT|AMOUNT\s*DUE|TOTAL\s*DUE|NET\s*TOTAL|^TOTAL)",
    re.IGNORECASE,
)
MONEY_PATTERN = re.compile(
    r"(?<![\d.])(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})|\d+\.\d{2})(?!\d)")

DATE_PATTERNS = [
    # DD/MM/YYYY or DD-MM-YYYY
    re.compile(r"\b(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b"),
    # YYYY-MM-DD
    re.compile(r"\b(\d{4}-\d{1,2}-\d{1,2})\b"),
    # 15 JAN 2019 / 15 January 2019
    re.compile(
        r"\b(\d{1,2}\s+(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\s+\d{2,4})\b",
        re.IGNORECASE,
    ),
]

COMPANY_SUFFIXES = re.compile(
    r"\b(SDN\s*BHD|ENTERPRISE|TRADING|SERVICES?|STORE|MARKET|SHOP|SUPPLIES|"
    r"RESTAURANT|CAFE|HARDWARE|INDUSTRIES|CORPORATION|CORP|CO\.?\s*LTD|LLC|INC)\b",
    re.IGNORECASE,
)
NOISE_LINE = re.compile(
    r"^[\W_]*$|COPY|RECEIPT|INVOICE|TAX\s*INVOICE", re.IGNORECASE)


@dataclass
class FieldResult:
    value: Optional[str]
    confidence: float
    reason: str


@dataclass
class ExtractionResult:
    company: FieldResult
    date: FieldResult
    total: FieldResult
    raw_text: str
    anomaly_flags: list = field(default_factory=list)

    @property
    def overall_confidence(self) -> float:
        vals = [self.company.confidence,
                self.date.confidence, self.total.confidence]
        return round(sum(vals) / len(vals), 3)


# [patch v2: tiered total extraction]
CASH_LINE = re.compile(r"^\s*CASH\b", re.IGNORECASE)


def extract_total(lines: list[str]) -> FieldResult:
    candidates = []  # (index, line, [money values as float])
    for i, line in enumerate(lines):
        if not TOTAL_KEYWORDS.search(line):
            continue
        has_gst = re.search(r"GST", line, re.IGNORECASE)
        has_tax = re.search(r"\bTAX\b", line, re.IGNORECASE)
        has_rate = re.search(r"\d+(?:\.\d+)?\s*%", line)
        has_incl = re.search(r"INCL|NETT|NET\b", line, re.IGNORECASE)
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


def extract_date(lines: list[str]) -> FieldResult:
    for line in lines:
        for pattern in DATE_PATTERNS:
            m = pattern.search(line)
            if m:
                return FieldResult(m.group(1), 0.9, f"matched date pattern in line: {line.strip()!r}")
    return FieldResult(None, 0.0, "no date pattern matched")


# [patch v2: company sanity filters]
_C_NOISE = re.compile(
    r"COPY|RECEIPT|INVOICE|CASH\s*SALE|CASH\s*BILL|DUPLICATE|ORIGINAL", re.IGNORECASE)
_C_ADDRESS = re.compile(
    r"\b(JALAN|JLN|LORONG|LOT|TAMAN|BANDAR|KAWASAN|BLOK|BLOCK|LEVEL|FLOOR|TEL|FAX|PHONE|"
    r"GST|ROC|EMAIL|WWW)\b|\bNO\.?\s*\d|@|\b\d{5}\b", re.IGNORECASE)
_C_LEGAL = re.compile(r"\b(SDN\.?\s*BHD\.?|S/B|BHD|LTD|LLC|INC|CORP|CORPORATION|PLC)\b",
                      re.IGNORECASE)
_C_HINT = re.compile(
    r"\b(SDN\.?\s*BHD|S/B|BHD|ENTERPRISES?|TRADING|SERVICES?|STORE|MARKET|MART|SHOP|SUPPLIES|"
    r"RESTAURANT|CAFE|HARDWARE|INDUSTRIES|CORPORATION|CORP|LTD|LLC|INC|PHARMACY|STATIONERY|"
    r"GROCER|KOPITIAM)\b", re.IGNORECASE)


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


def extract_fields(raw_text: str) -> ExtractionResult:
    lines = [l for l in raw_text.splitlines() if l.strip()]

    company = extract_company(lines)
    date = extract_date(lines)
    total = extract_total(lines)

    anomalies = []
    if company.value is None:
        anomalies.append("no_company_match")
    if date.value is None:
        anomalies.append("no_date_match")
    if total.value is None:
        anomalies.append("no_total_match")

    return ExtractionResult(company=company, date=date, total=total, raw_text=raw_text, anomaly_flags=anomalies)


def extract_from_image(image_path: str) -> ExtractionResult:
    raw_text = run_ocr(image_path)
    return extract_fields(raw_text)

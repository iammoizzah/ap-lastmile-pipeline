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
MONEY_PATTERN = re.compile(r"(?<![\d.])(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})|\d+\.\d{2})(?!\d)")

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
NOISE_LINE = re.compile(r"^[\W_]*$|COPY|RECEIPT|INVOICE|TAX\s*INVOICE", re.IGNORECASE)


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
        vals = [self.company.confidence, self.date.confidence, self.total.confidence]
        return round(sum(vals) / len(vals), 3)


def extract_total(lines: list[str]) -> FieldResult:
    # Pass 1: look for an explicit "TOTAL"-style keyword line with a money value
    for line in lines:
        if TOTAL_KEYWORDS.search(line):
            m = MONEY_PATTERN.findall(line)
            if m:
                value = m[-1].replace(",", "")
                return FieldResult(value, 0.9, f"matched keyword line: {line.strip()!r}")

    # Pass 2: fallback — largest money value anywhere in the document
    all_amounts = []
    for line in lines:
        for m in MONEY_PATTERN.findall(line):
            try:
                all_amounts.append(float(m.replace(",", "")))
            except ValueError:
                continue
    if all_amounts:
        value = f"{max(all_amounts):.2f}"
        return FieldResult(value, 0.5, "fallback: largest money value on receipt (no TOTAL keyword found)")

    return FieldResult(None, 0.0, "no money values found")


def extract_date(lines: list[str]) -> FieldResult:
    for line in lines:
        for pattern in DATE_PATTERNS:
            m = pattern.search(line)
            if m:
                return FieldResult(m.group(1), 0.9, f"matched date pattern in line: {line.strip()!r}")
    return FieldResult(None, 0.0, "no date pattern matched")


def extract_company(lines: list[str]) -> FieldResult:
    candidates = [l for l in lines[:8] if l.strip() and not NOISE_LINE.match(l.strip())]

    # Pass 1: a line with a company-like suffix (SDN BHD, ENTERPRISE, etc.)
    for line in candidates:
        if COMPANY_SUFFIXES.search(line):
            return FieldResult(line.strip(), 0.8, f"matched company-suffix pattern: {line.strip()!r}")

    # Pass 2: fallback — first substantial all-caps-ish line near the top
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


"""
Matching service: validates AI-extracted invoice data against a second
source of truth (vendor master + purchase orders) and decides where the
invoice goes next.

Why this exists: the extractor's own confidence is a weak signal. In our
eval, wrong totals regularly came out with high confidence. Cross-checking
against data the extractor never saw (a PO says this vendor should bill
about this amount) catches errors the extractor cannot catch about itself.

Everything here is a pure function: no DB, no I/O. The DB wrapper lives in
pipeline.py. That keeps the business rules easy to unit test and easy to
explain to a customer's finance team.
"""
import re
from dataclasses import dataclass, field, asdict
from datetime import date, datetime, timedelta
from difflib import SequenceMatcher
from typing import Optional

# --- Config ------------------------------------------------------------------
# Per-tenant overrides live in Tenant.config (JSON). Anything not set there
# falls back to these defaults, so a new tenant works with zero setup.
DEFAULT_CONFIG = {
    "vendor_match_threshold": 0.85,   # similarity at/above which a vendor counts as matched
    "vendor_weak_threshold": 0.60,    # between weak and match -> linked but flagged
    "amount_tolerance_pct": 2.0,      # allowed gap between invoice total and PO amount
    "min_extraction_confidence": 0.70,  # below this -> low_extraction_confidence flag
    "fast_track_min_extraction_confidence": 0.85,
    "fast_track_min_match_confidence": 0.85,
    # Safety default: even "fast track" invoices wait for a human unless the
    # tenant explicitly opts in. Nothing auto-approves out of the box.
    "auto_approve_enabled": False,
}

# code -> severity. High-severity flags force the reviewer to justify an approval.
FLAG_SEVERITY = {
    "missing_vendor": "high",
    "missing_total": "high",
    "no_vendor_match": "high",
    "amount_mismatch": "high",
    "duplicate_invoice": "high",
    "weak_vendor_match": "medium",
    "no_po_match": "medium",
    "future_date": "high",
    "possible_duplicate": "medium",
    "low_extraction_confidence": "medium",
    "implausible_date": "medium",
    "missing_date": "low",
}

SEVERITY_WEIGHT = {"high": 0.30, "medium": 0.15, "low": 0.05}

LEGAL_SUFFIXES = {
    "SDN", "BHD", "LTD", "LLC", "INC", "CORP", "CORPORATION", "CO",
    "PLC", "PTE", "LIMITED", "COMPANY",
}


def get_config(tenant_config: Optional[dict]) -> dict:
    return {**DEFAULT_CONFIG, **(tenant_config or {})}


# --- Data shapes ---------------------------------------------------------------
@dataclass
class Flag:
    code: str
    reason: str
    severity: str

    def to_dict(self) -> dict:
        return asdict(self)


def make_flag(code: str, reason: str) -> Flag:
    return Flag(code=code, reason=reason, severity=FLAG_SEVERITY[code])


def normalize_flags(raw) -> list:
    """Stored flags can be dicts (current format) or plain strings (written by
    the Milestone 2 upload endpoint). Return a uniform list of Flag objects."""
    flags = []
    for item in raw or []:
        if isinstance(item, dict) and "code" in item:
            code = item["code"]
            flags.append(Flag(code, item.get("reason", ""),
                              item.get("severity", FLAG_SEVERITY.get(code, "medium"))))
        elif isinstance(item, str):
            flags.append(Flag(item, "", FLAG_SEVERITY.get(item, "medium")))
    return flags


@dataclass
class MatchResult:
    vendor_id: Optional[str] = None
    vendor_name: Optional[str] = None
    vendor_score: float = 0.0
    po_id: Optional[str] = None
    po_number: Optional[str] = None
    po_expected_amount: Optional[float] = None
    amount_diff_pct: Optional[float] = None
    match_confidence: float = 0.0
    flags: list = field(default_factory=list)
    route: str = "review"
    risk_score: float = 1.0

    def to_dict(self) -> dict:
        d = asdict(self)
        d["flags"] = [f.to_dict() if isinstance(f, Flag) else f for f in self.flags]
        return d


# --- Name matching ---------------------------------------------------------------
def normalize_name(name: Optional[str]) -> str:
    """Uppercase, strip punctuation and legal suffixes (SDN BHD, LTD, ...)."""
    if not name:
        return ""
    cleaned = re.sub(r"[^A-Z0-9 ]", " ", name.upper())
    tokens = [t for t in cleaned.split() if t not in LEGAL_SUFFIXES]
    return " ".join(tokens)


def name_similarity(a: Optional[str], b: Optional[str]) -> float:
    na, nb = normalize_name(a), normalize_name(b)
    if not na or not nb:
        return 0.0
    ratio = SequenceMatcher(None, na, nb).ratio()
    # OCR often captures only part of a name; treat clean containment as a strong match.
    shorter, longer = sorted((na, nb), key=len)
    if len(shorter) >= 5 and shorter in longer:
        ratio = max(ratio, 0.9)
    return round(ratio, 3)


def _best_vendor(vendor_text: str, vendors: list):
    best, best_score = None, 0.0
    for v in vendors:
        names = [v["name"]] + list(v.get("known_aliases") or [])
        score = max(name_similarity(vendor_text, n) for n in names)
        if score > best_score:
            best, best_score = v, score
    return best, best_score


def _fmt(amount: float) -> str:
    return f"{amount:,.2f}"


# --- Date sanity ---------------------------------------------------------------
_DATE_FORMATS = ["%d/%m/%Y", "%d-%m-%Y", "%d/%m/%y", "%d-%m-%y", "%Y-%m-%d",
                 "%d %b %Y", "%d %b %y", "%d %B %Y", "%d %B %y"]


def parse_date(text: Optional[str]) -> Optional[date]:
    if not text:
        return None
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(text.strip(), fmt).date()
        except ValueError:
            continue
    return None


# --- Core evaluation ---------------------------------------------------------------
def evaluate_invoice(
    *,
    vendor_text: Optional[str],
    date_text: Optional[str],
    total: Optional[float],
    extraction_confidence: Optional[float],
    vendors: list,
    purchase_orders: list,
    existing_invoices: list,
    config: Optional[dict] = None,
    today: Optional[date] = None,
) -> MatchResult:
    """
    vendors:           [{id, name, known_aliases}]
    purchase_orders:   [{id, po_number, vendor_id, expected_amount, status}]
    existing_invoices: [{id, vendor, date, total}]  (other invoices, not this one)
    """
    cfg = get_config(config)
    ext_conf = extraction_confidence or 0.0
    result = MatchResult()
    flags = []

    # 1. Missing or implausible fields
    today = today or date.today()
    if not vendor_text:
        flags.append(make_flag("missing_vendor", "No vendor name could be extracted."))
    elif not normalize_name(vendor_text):
        # e.g. the extractor returned just "SDN BHD": a legal suffix, not a name.
        flags.append(make_flag(
            "missing_vendor",
            f"Extracted vendor '{vendor_text}' is only a legal suffix, not a company name."))
        vendor_text = None  # don't try to match or dedupe on it
    if total is None:
        flags.append(make_flag("missing_total", "No total amount could be extracted."))
    if not date_text:
        flags.append(make_flag("missing_date", "No invoice date could be extracted."))
    else:
        parsed = parse_date(date_text)
        if parsed is not None and parsed > today + timedelta(days=1):
            flags.append(make_flag(
                "future_date", f"Invoice date {date_text} is in the future (likely an OCR misread)."))
        elif parsed is not None and parsed.year < 2000:
            flags.append(make_flag(
                "implausible_date", f"Invoice date {date_text} is before the year 2000."))
    if ext_conf < cfg["min_extraction_confidence"]:
        flags.append(make_flag(
            "low_extraction_confidence",
            f"Extraction confidence {ext_conf:.2f} is below the tenant minimum "
            f"{cfg['min_extraction_confidence']:.2f}."))

    # 2. Vendor match
    vendor, score = (None, 0.0)
    if vendor_text:
        vendor, score = _best_vendor(vendor_text, vendors)
        if vendor is None or score < cfg["vendor_weak_threshold"]:
            vendor = None
            flags.append(make_flag(
                "no_vendor_match",
                f"'{vendor_text}' does not match any known vendor "
                f"(best similarity {score:.2f}), so no PO can be matched."))
        elif score < cfg["vendor_match_threshold"]:
            flags.append(make_flag(
                "weak_vendor_match",
                f"'{vendor_text}' only loosely matches vendor '{vendor['name']}' "
                f"(similarity {score:.2f})."))
    if vendor:
        result.vendor_id, result.vendor_name, result.vendor_score = vendor["id"], vendor["name"], score

    # 3. PO match + amount check (only meaningful once we know the vendor)
    po, amount_ok = None, False
    if vendor and total is not None:
        open_pos = [p for p in purchase_orders
                    if p["vendor_id"] == vendor["id"] and p.get("status", "open") == "open"]
        if not open_pos:
            flags.append(make_flag(
                "no_po_match", f"Vendor '{vendor['name']}' has no open purchase order."))
        else:
            po = min(open_pos, key=lambda p: abs(p["expected_amount"] - total))
            expected = po["expected_amount"]
            diff_pct = abs(total - expected) / expected * 100 if expected else 100.0
            result.po_id, result.po_number = po["id"], po["po_number"]
            result.po_expected_amount = expected
            result.amount_diff_pct = round(diff_pct, 2)
            amount_ok = diff_pct <= cfg["amount_tolerance_pct"]
            if not amount_ok:
                flags.append(make_flag(
                    "amount_mismatch",
                    f"Invoice total {_fmt(total)} differs from PO {po['po_number']} "
                    f"amount {_fmt(expected)} by {diff_pct:.1f}% "
                    f"(tolerance {cfg['amount_tolerance_pct']:.1f}%)."))

    # 4. Duplicate detection against earlier invoices
    if vendor_text and total is not None:
        exact, possible = None, None
        for other in existing_invoices:
            if other.get("total") is None or abs(other["total"] - total) > 0.005:
                continue
            if name_similarity(vendor_text, other.get("vendor")) < cfg["vendor_match_threshold"]:
                continue
            same_date = (date_text and other.get("date")
                         and date_text.strip().upper() == str(other["date"]).strip().upper())
            if same_date:
                exact = exact or other
            else:
                possible = possible or other
        if exact:
            flags.append(make_flag(
                "duplicate_invoice",
                f"Same vendor, date and total ({_fmt(total)}) as invoice {exact['id'][:8]}."))
        elif possible:
            flags.append(make_flag(
                "possible_duplicate",
                f"Same vendor and total ({_fmt(total)}) as invoice {possible['id'][:8]} "
                f"but a different date."))

    # 5. Match confidence: how much do we trust the link to the system of record?
    if not vendor:
        match_conf = 0.0
    elif po is None:
        match_conf = score * 0.5
    elif amount_ok:
        match_conf = score
    else:
        match_conf = score * 0.6
    result.match_confidence = round(match_conf, 3)
    result.flags = flags
    result.route = decide_route(flags, ext_conf, result.match_confidence, cfg)
    result.risk_score = risk_score(flags, ext_conf, result.match_confidence)
    return result


def decide_route(flags: list, extraction_confidence: float, match_confidence: float,
                 config: Optional[dict] = None) -> str:
    """'fast_track' only when nothing is wrong AND both the extractor and the
    PO match are confident. Everything else goes to full human review."""
    cfg = get_config(config)
    if (not flags
            and (extraction_confidence or 0) >= cfg["fast_track_min_extraction_confidence"]
            and (match_confidence or 0) >= cfg["fast_track_min_match_confidence"]):
        return "fast_track"
    return "review"


def risk_score(flags: list, extraction_confidence: Optional[float],
               match_confidence: Optional[float]) -> float:
    """0-1 ordering aid for the review queue (highest risk first). A heuristic,
    not a calibrated probability: it exists so reviewers see the worst first."""
    flag_part = sum(SEVERITY_WEIGHT.get(f.severity, 0.15) for f in flags)
    score = (0.35 * (1 - (extraction_confidence or 0))
             + 0.25 * (1 - (match_confidence or 0))
             + flag_part * 0.5)
    return round(min(1.0, score), 2)

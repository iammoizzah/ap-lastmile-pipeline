#!/usr/bin/env bash
# Milestone 3 update. Run from the REPO ROOT (the folder containing backend/).
# Replaces backend/app/services/matching.py and the test files from the first Milestone 3 install,
# and adds scripts/eval_pipeline.py and scripts/apply_fixes.py.
# Does NOT touch extraction.py or eval_extraction.py; apply_fixes.py patches those, with checks.
set -e
if [ ! -d backend/app ]; then echo "Run this from the repo root (folder containing backend/)."; exit 1; fi

mkdir -p "$(dirname "backend/app/services/matching.py")"
cat > "backend/app/services/matching.py" << 'M3_EOF'
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
M3_EOF

mkdir -p "$(dirname "backend/tests/__init__.py")"
cat > "backend/tests/__init__.py" << 'M3_EOF'

M3_EOF

mkdir -p "$(dirname "backend/tests/conftest.py")"
cat > "backend/tests/conftest.py" << 'M3_EOF'
"""Shared fixtures: a TestClient wired to an in-memory SQLite database with one
tenant, one vendor and one open PO. OCR is stubbed so no Tesseract is needed."""
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.database import Base, get_db
from app.main import app
from app.models import models
from app.routes import invoices as invoices_route
from app.services.extraction import ExtractionResult, FieldResult


def fake_extraction(company, date, total):
    """Build an extraction result with fixed confidences, independent of the OCR/regex logic."""
    def field(value, confidence):
        return FieldResult(value=value, confidence=confidence if value is not None else 0.0,
                           reason="test stub")
    return ExtractionResult(company=field(company, 0.8), date=field(date, 0.9),
                            total=field(total, 0.9), raw_text="")


@pytest.fixture()
def client(monkeypatch, tmp_path):
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False},
                           poolclass=StaticPool)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, autoflush=False, autocommit=False)

    # seed one tenant, one vendor, one open PO
    with Session() as db:
        t = models.Tenant(name="Test Co", config={})
        db.add(t); db.flush()
        v = models.Vendor(tenant_id=t.id, name="OJC MARKETING SDN BHD",
                          known_aliases=["OJC MARKETING"])
        db.add(v); db.flush()
        db.add(models.PurchaseOrder(tenant_id=t.id, po_number="PO-1001", vendor_id=v.id,
                                    expected_amount=193.00, status="open"))
        db.commit()

    def override_get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    monkeypatch.setattr(invoices_route, "UPLOAD_DIR", str(tmp_path))

    # Stub extraction: the image content is irrelevant. Tests set texts["current"] to a
    # (company, date, total) tuple before each upload.
    texts = {}
    monkeypatch.setattr(invoices_route, "extract_from_image",
                        lambda path: fake_extraction(*texts["current"]))

    c = TestClient(app)
    c.texts = texts
    c.Session = Session
    yield c
    app.dependency_overrides.clear()
M3_EOF

mkdir -p "$(dirname "backend/tests/test_matching.py")"
cat > "backend/tests/test_matching.py" << 'M3_EOF'
"""Unit tests for the pure matching rules (no DB, no HTTP)."""
from app.services.matching import (
    decide_route, evaluate_invoice, name_similarity, normalize_name, risk_score, make_flag,
)

VENDORS = [
    {"id": "v1", "name": "OJC MARKETING SDN BHD", "known_aliases": ["OJC MARKETING"]},
    {"id": "v2", "name": "Speed Mart S/B", "known_aliases": []},
]
POS = [
    {"id": "p1", "po_number": "PO-1001", "vendor_id": "v1", "expected_amount": 193.00, "status": "open"},
    {"id": "p2", "po_number": "PO-1002", "vendor_id": "v1", "expected_amount": 5000.00, "status": "open"},
    {"id": "p3", "po_number": "PO-2001", "vendor_id": "v2", "expected_amount": 80.00, "status": "closed"},
]


def evaluate(**kw):
    base = dict(vendor_text="OJC MARKETING SDN BHD", date_text="15/01/2019", total=193.00,
                extraction_confidence=0.9, vendors=VENDORS, purchase_orders=POS,
                existing_invoices=[])
    base.update(kw)
    return evaluate_invoice(**base)


def codes(result):
    return {f.code for f in result.flags}


def test_normalize_strips_legal_suffixes_and_punctuation():
    assert normalize_name("OJC Marketing Sdn. Bhd.") == "OJC MARKETING"


def test_similarity_tolerates_partial_ocr_names():
    assert name_similarity("OJC MARKETING", "OJC MARKETING SDN BHD") >= 0.85
    assert name_similarity("COMPLETELY DIFFERENT", "OJC MARKETING SDN BHD") < 0.5


def test_clean_invoice_has_no_flags_and_is_fast_tracked():
    r = evaluate()
    assert r.flags == []
    assert r.po_number == "PO-1001"
    assert r.route == "fast_track"
    assert r.risk_score < 0.15


def test_picks_closest_open_po_by_amount():
    r = evaluate(total=4990.00)
    assert r.po_number == "PO-1002"
    assert "amount_mismatch" not in codes(r)  # within 2% tolerance


def test_amount_mismatch_is_flagged_high_severity():
    r = evaluate(total=250.00)
    assert "amount_mismatch" in codes(r)
    assert any(f.severity == "high" for f in r.flags)
    assert r.route == "review"


def test_unknown_vendor_flags_no_vendor_match_and_zero_match_confidence():
    r = evaluate(vendor_text="TOTALLY UNKNOWN TRADING")
    assert "no_vendor_match" in codes(r)
    assert r.match_confidence == 0.0
    assert r.po_id is None


def test_vendor_with_only_closed_po_flags_no_po_match():
    r = evaluate(vendor_text="Speed Mart S/B", total=80.00)
    assert "no_po_match" in codes(r)
    assert "no_vendor_match" not in codes(r)


def test_low_extraction_confidence_blocks_fast_track():
    r = evaluate(extraction_confidence=0.5)
    assert "low_extraction_confidence" in codes(r)
    assert r.route == "review"


def test_missing_fields_are_flagged():
    r = evaluate(vendor_text=None, total=None, date_text=None)
    assert {"missing_vendor", "missing_total", "missing_date"} <= codes(r)


def test_exact_duplicate_detected():
    existing = [{"id": "abcdef123456", "vendor": "OJC MARKETING SDN BHD",
                 "date": "15/01/2019", "total": 193.00}]
    assert "duplicate_invoice" in codes(evaluate(existing_invoices=existing))


def test_same_vendor_and_total_different_date_is_possible_duplicate():
    existing = [{"id": "abcdef123456", "vendor": "OJC MARKETING SDN BHD",
                 "date": "01/02/2019", "total": 193.00}]
    c = codes(evaluate(existing_invoices=existing))
    assert "possible_duplicate" in c and "duplicate_invoice" not in c


def test_tenant_config_overrides_defaults():
    # 10% tolerance makes a 5% gap acceptable
    r = evaluate(total=202.65, config={"amount_tolerance_pct": 10.0})
    assert "amount_mismatch" not in codes(r)


def test_risk_orders_worse_invoices_higher():
    clean = risk_score([], 0.9, 0.95)
    bad = risk_score([make_flag("amount_mismatch", "x"), make_flag("duplicate_invoice", "y")], 0.5, 0.3)
    assert bad > clean


def test_decide_route_requires_both_confidences():
    assert decide_route([], 0.9, 0.9) == "fast_track"
    assert decide_route([], 0.9, 0.4) == "review"
    assert decide_route([make_flag("no_po_match", "x")], 0.99, 0.99) == "review"


# --- date and vendor sanity (added after the first 40-receipt run) -------------------
from datetime import date

TODAY = date(2026, 10, 17)


def test_future_date_is_flagged_high_severity():
    # a real case from the SROIE run: OCR read 2018 as 2078
    r = evaluate(date_text="09/02/2078", today=TODAY)
    assert "future_date" in codes(r)
    assert any(f.code == "future_date" and f.severity == "high" for f in r.flags)
    assert r.route == "review"


def test_normal_old_receipt_date_is_fine():
    assert "future_date" not in codes(evaluate(date_text="15/01/2019", today=TODAY))
    assert "future_date" not in codes(evaluate(date_text="20/03/18", today=TODAY))


def test_pre_2000_date_is_implausible():
    assert "implausible_date" in codes(evaluate(date_text="01/01/1978", today=TODAY))


def test_unparseable_date_is_not_flagged_as_future():
    c = codes(evaluate(date_text="gibberish", today=TODAY))
    assert "future_date" not in c and "implausible_date" not in c


def test_legal_suffix_only_vendor_counts_as_missing_not_unknown():
    r = evaluate(vendor_text="SDN BHD")
    assert "missing_vendor" in codes(r)
    assert "no_vendor_match" not in codes(r)
    assert r.route == "review"


def test_legal_suffix_only_vendor_does_not_trigger_duplicate_check():
    existing = [{"id": "abcdef123456", "vendor": "SDN BHD", "date": "15/01/2019", "total": 193.00}]
    assert "duplicate_invoice" not in codes(evaluate(vendor_text="SDN BHD", existing_invoices=existing))
M3_EOF

mkdir -p "$(dirname "backend/tests/test_review_flow.py")"
cat > "backend/tests/test_review_flow.py" << 'M3_EOF'
"""
End-to-end test of upload -> match -> review queue -> decision -> audit trail,
through the real FastAPI routes against an in-memory SQLite database.
Extraction is stubbed, so these tests cover matching and review only.
"""
import io

from PIL import Image


# (company, date, total) as the extractor would return them
RECEIPT_OJC = ("OJC MARKETING SDN BHD", "15/01/2019", "193.00")
RECEIPT_UNKNOWN = ("MYSTERY TRADING SDN BHD", "02/02/2019", "77.50")
RECEIPT_OJC_WRONG_TOTAL = ("OJC MARKETING SDN BHD", "20/01/2019", "410.00")


def png_bytes():
    buf = io.BytesIO()
    Image.new("RGB", (4, 4), "white").save(buf, format="PNG")
    return buf.getvalue()


def upload(client, extracted, name="r.png"):
    client.texts["current"] = extracted
    return client.post("/invoices/upload", files={"file": (name, png_bytes(), "image/png")})


def test_clean_invoice_matches_po_and_is_fast_track_but_still_pending(client):
    r = upload(client, RECEIPT_OJC)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["matching"]["po_number"] == "PO-1001"
    assert body["matching"]["flags"] == []
    assert body["route"] == "fast_track"
    assert body["status"] == "pending_review"  # nothing auto-approves by default


def test_upload_rejects_wrong_file_type(client):
    r = client.post("/invoices/upload", files={"file": ("x.exe", b"nope", "application/octet-stream")})
    assert r.status_code == 415


def test_unknown_vendor_is_flagged_and_needs_override_reason_to_approve(client):
    inv = upload(client, RECEIPT_UNKNOWN).json()
    assert "no_vendor_match" in [f["code"] for f in inv["matching"]["flags"]]

    no_reason = client.post(f"/review/{inv['invoice_id']}/decision", json={"action": "approve"})
    assert no_reason.status_code == 422
    assert "override reason" in no_reason.json()["detail"]

    ok = client.post(f"/review/{inv['invoice_id']}/decision",
                     json={"action": "approve", "reason": "Known new supplier, verified by phone",
                           "reviewer": "alice"})
    assert ok.status_code == 200
    assert ok.json()["status"] == "approved"


def test_reject_requires_reason_and_cannot_be_decided_twice(client):
    inv = upload(client, RECEIPT_UNKNOWN).json()
    iid = inv["invoice_id"]
    assert client.post(f"/review/{iid}/decision", json={"action": "reject"}).status_code == 422
    assert client.post(f"/review/{iid}/decision",
                       json={"action": "reject", "reason": "Not our vendor"}).status_code == 200
    again = client.post(f"/review/{iid}/decision", json={"action": "approve", "reason": "oops"})
    assert again.status_code == 409


def test_edit_corrects_total_rematches_and_clears_flags(client):
    inv = upload(client, RECEIPT_OJC_WRONG_TOTAL).json()
    assert "amount_mismatch" in [f["code"] for f in inv["matching"]["flags"]]

    r = client.post(f"/review/{inv['invoice_id']}/decision",
                    json={"action": "edit", "edited_fields": {"total": "193.00"}})
    assert r.status_code == 200, r.text  # no override reason needed: edit resolved the flag
    assert r.json()["remaining_flags"] == []
    assert r.json()["status"] == "approved"


def test_duplicate_upload_is_flagged(client):
    upload(client, RECEIPT_OJC)
    second = upload(client, RECEIPT_OJC).json()
    assert "duplicate_invoice" in [f["code"] for f in second["matching"]["flags"]]


def test_queue_is_sorted_riskiest_first_and_excludes_decided(client):
    clean = upload(client, RECEIPT_OJC).json()
    risky = upload(client, RECEIPT_UNKNOWN).json()
    q = client.get("/review/queue").json()
    ids = [i["id"] for i in q["items"]]
    assert ids[0] == risky["invoice_id"] and ids[-1] == clean["invoice_id"]

    client.post(f"/review/{risky['invoice_id']}/decision",
                json={"action": "reject", "reason": "not ours"})
    assert risky["invoice_id"] not in [i["id"] for i in client.get("/review/queue").json()["items"]]


def test_audit_trail_records_ai_and_human_steps_with_before_after(client):
    inv = upload(client, RECEIPT_OJC_WRONG_TOTAL).json()
    client.post(f"/review/{inv['invoice_id']}/decision",
                json={"action": "edit", "edited_fields": {"total": "193.00"}, "reviewer": "bob"})
    trail = client.get(f"/review/{inv['invoice_id']}").json()["audit_trail"]
    assert [a["action"] for a in trail] == ["invoice_extracted", "invoice_matched", "invoice_edit"]
    assert trail[0]["actor"] == "system" and trail[2]["actor"] == "reviewer:bob"
    assert trail[2]["before"]["total"] == 410.0 and trail[2]["after"]["total"] == 193.0
    assert trail[2]["before"]["status"] == "pending_review" and trail[2]["after"]["status"] == "approved"
M3_EOF

mkdir -p "$(dirname "backend/tests/test_pipeline_eval.py")"
cat > "backend/tests/test_pipeline_eval.py" << 'M3_EOF'
"""Tests for scripts/eval_pipeline.py: the scoring maths and the upload-and-score driver."""
import json

from PIL import Image

from scripts.eval_pipeline import run_eval, score
from tests.conftest import fake_extraction
from app.routes import invoices as invoices_route


def rec(route, correct, ext_conf=0.87, flags=()):
    return {"key": "k", "route": route, "flags": list(flags), "ext_conf": ext_conf,
            "risk": 0.1, "vendor_ok": correct, "total_ok": correct, "correct": correct}


def test_score_counts_catches_escapes_and_false_alarms():
    records = [
        rec("fast_track", True),                      # right, fast-tracked
        rec("fast_track", False),                     # wrong, ESCAPED to fast-track
        rec("review", False, flags=["amount_mismatch"]),   # wrong, caught
        rec("review", True, flags=["no_vendor_match"]),    # right but reviewed: false alarm
    ]
    s = score(records)
    assert s["n"] == 4 and s["fully_correct"] == 2 and s["wrong_total"] == 2
    sy = s["system"]
    assert sy["fast_tracked"] == 2 and sy["fast_tracked_wrong"] == 1
    assert sy["fast_track_precision_pct"] == 50.0
    assert sy["review_actually_wrong"] == 1 and sy["review_false_alarms"] == 1
    assert sy["wrong_caught_pct"] == 50.0 and sy["wrong_escaped"] == 1
    assert s["flag_counts"] == {"amount_mismatch": 1, "no_vendor_match": 1}


def test_score_baseline_uses_extraction_confidence_only():
    records = [rec("review", False, ext_conf=0.9), rec("review", False, ext_conf=0.5),
               rec("fast_track", True, ext_conf=0.9)]
    b = score(records)["confidence_only_baseline"]
    assert b["would_skip_review"] == 2 and b["of_those_wrong"] == 1 and b["wrong_escaped"] == 1


def test_score_handles_empty_and_all_correct():
    assert score([])["fully_correct_pct"] is None
    s = score([rec("fast_track", True), rec("fast_track", True)])
    assert s["system"]["wrong_caught_pct"] is None and s["system"]["fast_track_precision_pct"] == 100.0


def test_driver_end_to_end_through_the_real_api(client, monkeypatch, tmp_path):
    # (extracted company, date, total) -> ground truth (company, total)
    cases = [
        (("OJC MARKETING SDN BHD", "15/01/2019", "193.00"), ("OJC MARKETING SDN BHD", "193.00")),  # A correct, clean
        (("OJC MARKETING SDN BHD", "16/01/2019", "250.00"), ("OJC MARKETING SDN BHD", "193.00")),  # B wrong, caught by PO check
        (("MYSTERY TRADING SDN BHD", "02/02/2019", "77.50"), ("MYSTERY TRADING SDN BHD", "77.50")),  # C right, unknown vendor
        (("OJC MARKETING SDN BHD", "17/01/2019", "190.00"), ("OJC MARKETING SDN BHD", "187.00")),  # D wrong but within PO tolerance
    ]
    paths, queue = [], []
    for i, (extracted, (company, total)) in enumerate(cases):
        p = tmp_path / f"r{i}.jpg"
        Image.new("RGB", (4, 4), "white").save(p, format="JPEG")
        json.dump({"key": f"r{i}", "entities": {"company": company, "total": total}},
                  open(tmp_path / f"r{i}.json", "w"))
        paths.append(str(p))
        queue.append(extracted)
    monkeypatch.setattr(invoices_route, "extract_from_image",
                        lambda path: fake_extraction(*queue.pop(0)))

    records = run_eval(client, "", paths)
    s = score(records)

    assert [r["route"] for r in records] == ["fast_track", "review", "review", "fast_track"]
    assert [r["correct"] for r in records] == [True, False, True, False]
    assert s["system"]["fast_tracked_wrong"] == 1          # D escaped
    assert s["system"]["wrong_caught_pct"] == 50.0         # B caught, D escaped
    assert s["system"]["review_false_alarms"] == 1         # C
    assert s["confidence_only_baseline"]["wrong_escaped"] == 2  # confidence alone lets both through


def test_driver_refuses_to_run_on_a_dirty_table(client, tmp_path):
    client.texts["current"] = ("OJC MARKETING SDN BHD", "15/01/2019", "193.00")
    from tests.test_review_flow import png_bytes
    client.post("/invoices/upload", files={"file": ("x.png", png_bytes(), "image/png")})
    import pytest
    with pytest.raises(SystemExit) as e:
        run_eval(client, "", [])
    assert "already has" in str(e.value)
M3_EOF

mkdir -p "$(dirname "backend/tests/test_extraction_fixes.py")"
cat > "backend/tests/test_extraction_fixes.py" << 'M3_EOF'
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
M3_EOF

mkdir -p "$(dirname "backend/scripts/eval_pipeline.py")"
cat > "backend/scripts/eval_pipeline.py" << 'M3_EOF'
"""
Pipeline evaluation: how well does the WHOLE system (extraction + PO matching +
routing) protect the business, measured against SROIE ground truth?

It uploads receipts through the running API, then scores each result:
  * correct   = extracted vendor AND total both match the ground truth
  * the route the system chose (fast_track vs full review)

The headline comparison is against the naive alternative, "trust the extractor
when its own confidence is high". The gap between the two is the value of
cross-checking against a second source (vendor master + purchase orders).

IMPORTANT CAVEAT, print it in any write-up: the purchase orders in this demo
are generated from the same ground truth (scripts/seed_po_from_sroie.py), so
the PO check has an easier job here than against a real ERP. Treat the numbers
as a demonstration of the mechanism, not a prediction of production accuracy.

Needs the API running and an EMPTY invoices table (re-uploading the same
receipts would make them all look like duplicates).

Usage:
    cd backend
    python3 scripts/eval_pipeline.py --n 100
"""
import argparse
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

RECEIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data", "receipts"))
BASELINE_CONFIDENCE = 0.85  # same bar the system uses for fast-track


def norm_amount(value):
    try:
        return round(float(re.sub(r"[^\d.]", "", str(value))), 2)
    except (ValueError, TypeError):
        return None


def vendor_matches(extracted, truth) -> bool:
    from app.services.matching import name_similarity
    return bool(extracted and truth) and name_similarity(extracted, truth) >= 0.85


def run_eval(client, base_url: str, paths: list, require_empty: bool = True) -> list:
    """Upload each receipt through the API and score it against its ground truth.
    `client` needs .get/.post like requests.Session (a FastAPI TestClient works too)."""
    if require_empty:
        existing = client.get(f"{base_url}/invoices").json()
        if existing:
            raise SystemExit(
                f"The invoices table already has {len(existing)} rows. Clear it first so duplicates "
                "from earlier runs don't distort the numbers:\n  docker exec -it ap_pipeline_db psql "
                "-U ap_user -d ap_pipeline -c \"TRUNCATE review_decisions, expected_payments, "
                "invoices, audit_log CASCADE;\"\n(or pass --force)")

    records = []
    for i, path in enumerate(paths, 1):
        truth = (json.load(open(path[:-4] + ".json")).get("entities")) or {}
        with open(path, "rb") as f:
            r = client.post(f"{base_url}/invoices/upload",
                            files={"file": (os.path.basename(path), f, "image/jpeg")})
        if r.status_code != 200:
            print(f"  skipped {os.path.basename(path)}: HTTP {r.status_code}")
            continue
        body = r.json()
        got_vendor = body["extracted"]["company"]["value"]
        got_total = body["extracted"]["total"]["value"]
        vendor_ok = vendor_matches(got_vendor, truth.get("company"))
        total_ok = (norm_amount(got_total) is not None
                    and norm_amount(got_total) == norm_amount(truth.get("total")))
        records.append({
            "key": os.path.splitext(os.path.basename(path))[0],
            "route": body["route"],
            "flags": [f["code"] for f in body["matching"]["flags"]],
            "ext_conf": body["overall_confidence"],
            "risk": body["risk_score"],
            "vendor_ok": vendor_ok,
            "total_ok": total_ok,
            "correct": vendor_ok and total_ok,
        })
        if i % 10 == 0:
            print(f"  processed {i}/{len(paths)}")
    return records


def score(records: list, baseline_conf: float = BASELINE_CONFIDENCE) -> dict:
    n = len(records)
    wrong = [r for r in records if not r["correct"]]
    fast = [r for r in records if r["route"] == "fast_track"]
    review = [r for r in records if r["route"] == "review"]
    fast_wrong = [r for r in fast if not r["correct"]]
    review_wrong = [r for r in review if not r["correct"]]
    review_fine = [r for r in review if r["correct"]]
    base_pass = [r for r in records if r["ext_conf"] >= baseline_conf]
    base_wrong = [r for r in base_pass if not r["correct"]]

    def pct(a, b):
        return round(100 * a / b, 1) if b else None

    flag_counts = {}
    for r in records:
        for code in r["flags"]:
            flag_counts[code] = flag_counts.get(code, 0) + 1

    return {
        "n": n,
        "fully_correct": n - len(wrong),
        "fully_correct_pct": pct(n - len(wrong), n),
        "wrong_total": len(wrong),
        "system": {
            "fast_tracked": len(fast),
            "fast_tracked_wrong": len(fast_wrong),
            "fast_track_precision_pct": pct(len(fast) - len(fast_wrong), len(fast)),
            "sent_to_review": len(review),
            "review_actually_wrong": len(review_wrong),
            "review_false_alarms": len(review_fine),
            "wrong_caught_pct": pct(len(wrong) - len(fast_wrong), len(wrong)),
            "wrong_escaped": len(fast_wrong),
        },
        "confidence_only_baseline": {
            "threshold": baseline_conf,
            "would_skip_review": len(base_pass),
            "of_those_wrong": len(base_wrong),
            "wrong_caught_pct": pct(len(wrong) - len(base_wrong), len(wrong)),
            "wrong_escaped": len(base_wrong),
        },
        "flag_counts": dict(sorted(flag_counts.items(), key=lambda kv: -kv[1])),
    }


def print_report(s: dict):
    sy, bl = s["system"], s["confidence_only_baseline"]
    print(f"\n=== Pipeline evaluation over {s['n']} real SROIE receipts ===")
    print(f"\nExtraction alone: vendor AND total both correct on {s['fully_correct']}/{s['n']} "
          f"({s['fully_correct_pct']}%). {s['wrong_total']} invoices have a wrong vendor or total.")
    print("\nWith PO cross-check and routing (this system):")
    print(f"  fast-tracked:            {sy['fast_tracked']}  "
          f"(wrong among them: {sy['fast_tracked_wrong']}, precision {sy['fast_track_precision_pct']}%)")
    print(f"  sent to human review:    {sy['sent_to_review']}  "
          f"({sy['review_actually_wrong']} really wrong, {sy['review_false_alarms']} false alarms)")
    print(f"  wrong invoices caught:   {sy['wrong_caught_pct']}%  ({sy['wrong_escaped']} escaped to fast-track)")
    print(f"\nBaseline, trusting extraction confidence >= {bl['threshold']} alone:")
    print(f"  would skip review:       {bl['would_skip_review']}  (wrong among them: {bl['of_those_wrong']})")
    print(f"  wrong invoices caught:   {bl['wrong_caught_pct']}%  ({bl['wrong_escaped']} escaped)")
    print("\nFlags raised:", s["flag_counts"])
    print("\nCaveat: purchase orders here are generated from the same ground truth, so the PO "
          "check is easier than it would be against a real ERP.")


def main(n: int, url: str, force: bool):
    import requests
    paths = sorted(glob.glob(os.path.join(RECEIPTS_DIR, "*.jpg")))[:n]
    if not paths:
        raise SystemExit(f"No receipts in {RECEIPTS_DIR}. Run download_sroie.py first.")
    print(f"Uploading {len(paths)} receipts to {url} ...")
    records = run_eval(requests.Session(), url, paths, require_empty=not force)
    result = score(records)
    print_report(result)
    out = os.path.join(os.path.dirname(RECEIPTS_DIR), "pipeline_eval_report.json")
    with open(out, "w") as f:
        json.dump({"summary": result, "records": records}, f, indent=2)
    print(f"\nFull report: {out}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--n", type=int, default=100)
    p.add_argument("--url", default="http://localhost:8000")
    p.add_argument("--force", action="store_true", help="skip the empty-table check")
    a = p.parse_args()
    main(a.n, a.url, a.force)
M3_EOF

mkdir -p "$(dirname "backend/scripts/apply_fixes.py")"
cat > "backend/scripts/apply_fixes.py" << 'M3_EOF'
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
    if MARK_TOTAL in src and MARK_COMPANY in src:
        print("extraction.py: already patched, skipping.")
    else:
        new = src
        if MARK_TOTAL not in new:
            new = replace_function(new, "extract_total", TOTAL_BLOCK)
        if MARK_COMPANY not in new:
            new = replace_function(new, "extract_company", COMPANY_BLOCK)
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
M3_EOF

echo "Update written. Next: python3 backend/scripts/apply_fixes.py"

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

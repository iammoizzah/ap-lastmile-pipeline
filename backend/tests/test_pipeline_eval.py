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

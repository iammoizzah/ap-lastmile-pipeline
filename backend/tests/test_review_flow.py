"""
End-to-end test of upload -> match -> review queue -> decision -> audit trail,
through the real FastAPI routes against an in-memory SQLite database.
OCR is stubbed so the test needs no Tesseract and no image fixtures.
"""
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.database import Base, get_db
from app.main import app
from app.models import models
from app.routes import invoices as invoices_route
from app.services.extraction import extract_fields

RECEIPT_OJC = """OJC MARKETING SDN BHD
DATE : 15/01/2019 11:05:16 AM
TOTAL 193.00
"""
RECEIPT_UNKNOWN = """MYSTERY TRADING SDN BHD
DATE : 02/02/2019
TOTAL 77.50
"""
RECEIPT_OJC_WRONG_TOTAL = """OJC MARKETING SDN BHD
DATE : 20/01/2019
TOTAL 410.00
"""


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

    # Stub OCR: the "image" content is irrelevant; the text comes from the filename key.
    texts = {}
    monkeypatch.setattr(invoices_route, "extract_from_image",
                        lambda path: extract_fields(texts["current"]))

    c = TestClient(app)
    c.texts = texts
    c.Session = Session
    yield c
    app.dependency_overrides.clear()


def png_bytes():
    buf = io.BytesIO()
    Image.new("RGB", (4, 4), "white").save(buf, format="PNG")
    return buf.getvalue()


def upload(client, text, name="r.png"):
    client.texts["current"] = text
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

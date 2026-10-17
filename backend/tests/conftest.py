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

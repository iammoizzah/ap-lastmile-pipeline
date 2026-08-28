import os
import shutil
import uuid

from fastapi import APIRouter, UploadFile, File, HTTPException, Depends
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.models import Tenant, Invoice
from app.services.extraction import extract_from_image

router = APIRouter()

UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "uploads")


def _get_demo_tenant(db: Session) -> Tenant:
    """MVP shortcut: use the first seeded tenant. Replace with real auth-derived
    tenant lookup once Milestone 3's review UI needs actual multi-user login."""
    tenant = db.query(Tenant).first()
    if tenant is None:
        raise HTTPException(status_code=400, detail="No tenant found — run scripts/seed.py first")
    return tenant


@router.post("/upload")
def upload_invoice(file: UploadFile = File(...), db: Session = Depends(get_db)):
    tenant = _get_demo_tenant(db)

    os.makedirs(UPLOAD_DIR, exist_ok=True)
    ext = os.path.splitext(file.filename)[1] or ".jpg"
    saved_name = f"{uuid.uuid4()}{ext}"
    saved_path = os.path.join(UPLOAD_DIR, saved_name)

    with open(saved_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    result = extract_from_image(saved_path)

    total_value = None
    if result.total.value is not None:
        try:
            total_value = float(result.total.value)
        except ValueError:
            result.anomaly_flags.append("total_not_numeric")

    invoice = Invoice(
        tenant_id=tenant.id,
        source_file_url=saved_path,
        extracted_vendor=result.company.value,
        extracted_date=result.date.value,
        extracted_total=total_value,
        extracted_line_items=[],
        extraction_confidence=result.overall_confidence,
        extraction_method="ocr_rules",
        anomaly_flags=result.anomaly_flags,
        status="pending_review",
    )
    db.add(invoice)
    db.commit()
    db.refresh(invoice)

    return {
        "invoice_id": invoice.id,
        "status": invoice.status,
        "extracted": {
            "company": {"value": result.company.value, "confidence": result.company.confidence, "reason": result.company.reason},
            "date": {"value": result.date.value, "confidence": result.date.confidence, "reason": result.date.reason},
            "total": {"value": result.total.value, "confidence": result.total.confidence, "reason": result.total.reason},
        },
        "overall_confidence": result.overall_confidence,
        "anomaly_flags": result.anomaly_flags,
    }


@router.get("/{invoice_id}")
def get_invoice(invoice_id: str, db: Session = Depends(get_db)):
    invoice = db.query(Invoice).filter(Invoice.id == invoice_id).first()
    if invoice is None:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return {
        "id": invoice.id,
        "status": invoice.status,
        "extracted_vendor": invoice.extracted_vendor,
        "extracted_date": invoice.extracted_date,
        "extracted_total": invoice.extracted_total,
        "extraction_confidence": invoice.extraction_confidence,
        "anomaly_flags": invoice.anomaly_flags,
        "source_file_url": invoice.source_file_url,
    }


@router.get("")
def list_invoices(db: Session = Depends(get_db)):
    invoices = db.query(Invoice).order_by(Invoice.uploaded_at.desc()).limit(100).all()
    return [
        {
            "id": inv.id,
            "status": inv.status,
            "extracted_vendor": inv.extracted_vendor,
            "extracted_total": inv.extracted_total,
            "extraction_confidence": inv.extraction_confidence,
            "anomaly_flags": inv.anomaly_flags,
        }
        for inv in invoices
    ]


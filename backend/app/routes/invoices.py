import os
import uuid

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.models import Invoice
from app.services.audit import invoice_snapshot, log_event
from app.services.extraction import extract_from_image
from app.services.matching import get_config, normalize_flags
from app.services.pipeline import run_matching
from app.services.tenancy import get_demo_tenant

router = APIRouter()

UPLOAD_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "data", "uploads"))
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".webp"}
MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB


@router.post("/upload")
def upload_invoice(file: UploadFile = File(...), db: Session = Depends(get_db)):
    tenant = get_demo_tenant(db)

    # --- validate the upload (NFR: file type and size checks) ---
    ext = os.path.splitext(file.filename or "")[1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=415,
            detail=f"Unsupported file type '{ext or 'none'}'. Allowed: {sorted(ALLOWED_EXTENSIONS)}")

    os.makedirs(UPLOAD_DIR, exist_ok=True)
    saved_path = os.path.join(UPLOAD_DIR, f"{uuid.uuid4()}{ext}")
    size = 0
    with open(saved_path, "wb") as out:
        while chunk := file.file.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_UPLOAD_BYTES:
                out.close()
                os.remove(saved_path)
                raise HTTPException(status_code=413, detail="File too large (10 MB max).")
            out.write(chunk)

    # --- extract ---
    try:
        extraction = extract_from_image(saved_path)
    except Exception as e:  # unreadable image, tesseract missing, etc.
        os.remove(saved_path)
        raise HTTPException(status_code=422, detail=f"Could not extract text from file: {e}")

    total_value = None
    if extraction.total.value is not None:
        try:
            total_value = float(extraction.total.value)
        except ValueError:
            pass

    invoice = Invoice(
        tenant_id=tenant.id,
        source_file_url=saved_path,
        extracted_vendor=extraction.company.value,
        extracted_date=extraction.date.value,
        extracted_total=total_value,
        extracted_line_items=[],
        extraction_confidence=extraction.overall_confidence,
        extraction_method="ocr_rules",
        status="pending_review",
    )
    db.add(invoice)
    db.flush()  # assigns invoice.id

    log_event(
        db, tenant_id=tenant.id, actor="system", action="invoice_extracted",
        entity_type="invoice", entity_id=invoice.id, before=None,
        after={
            "vendor": {"value": extraction.company.value, "confidence": extraction.company.confidence,
                       "reason": extraction.company.reason},
            "date": {"value": extraction.date.value, "confidence": extraction.date.confidence,
                     "reason": extraction.date.reason},
            "total": {"value": extraction.total.value, "confidence": extraction.total.confidence,
                      "reason": extraction.total.reason},
            "overall_confidence": extraction.overall_confidence,
            "method": "ocr_rules",
        })

    # --- validate against the system of record, then route ---
    match = run_matching(db, invoice, tenant)
    log_event(
        db, tenant_id=tenant.id, actor="system", action="invoice_matched",
        entity_type="invoice", entity_id=invoice.id, before=None, after=match.to_dict())

    # Fast-track invoices still wait for a human unless the tenant opted in.
    if match.route == "fast_track" and get_config(tenant.config)["auto_approve_enabled"]:
        before = invoice_snapshot(invoice)
        invoice.status = "approved"
        log_event(
            db, tenant_id=tenant.id, actor="system", action="invoice_auto_approved",
            entity_type="invoice", entity_id=invoice.id, before=before,
            after=invoice_snapshot(invoice))

    db.commit()
    db.refresh(invoice)

    return {
        "invoice_id": invoice.id,
        "status": invoice.status,
        "route": match.route,
        "risk_score": match.risk_score,
        "extracted": {
            "company": {"value": extraction.company.value, "confidence": extraction.company.confidence,
                        "reason": extraction.company.reason},
            "date": {"value": extraction.date.value, "confidence": extraction.date.confidence,
                     "reason": extraction.date.reason},
            "total": {"value": extraction.total.value, "confidence": extraction.total.confidence,
                      "reason": extraction.total.reason},
        },
        "overall_confidence": extraction.overall_confidence,
        "matching": match.to_dict(),
    }


@router.get("")
def list_invoices(db: Session = Depends(get_db)):
    tenant = get_demo_tenant(db)
    invoices = (db.query(Invoice).filter(Invoice.tenant_id == tenant.id)
                .order_by(Invoice.uploaded_at.desc()).limit(100).all())
    return [
        {
            "id": inv.id,
            "status": inv.status,
            "extracted_vendor": inv.extracted_vendor,
            "extracted_total": inv.extracted_total,
            "extraction_confidence": inv.extraction_confidence,
            "match_confidence": inv.match_confidence,
            "flags": [f.code for f in normalize_flags(inv.anomaly_flags)],
        }
        for inv in invoices
    ]


@router.get("/{invoice_id}")
def get_invoice(invoice_id: str, db: Session = Depends(get_db)):
    tenant = get_demo_tenant(db)
    inv = db.query(Invoice).filter(Invoice.id == invoice_id, Invoice.tenant_id == tenant.id).first()
    if inv is None:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return {
        "id": inv.id,
        "status": inv.status,
        "extracted_vendor": inv.extracted_vendor,
        "extracted_date": inv.extracted_date,
        "extracted_total": inv.extracted_total,
        "extraction_confidence": inv.extraction_confidence,
        "match_confidence": inv.match_confidence,
        "matched_po_id": inv.matched_po_id,
        "flags": [f.to_dict() for f in normalize_flags(inv.anomaly_flags)],
    }


@router.get("/{invoice_id}/file")
def get_invoice_file(invoice_id: str, db: Session = Depends(get_db)):
    """Serves the original image so the review screen can show it next to the extracted fields."""
    tenant = get_demo_tenant(db)
    inv = db.query(Invoice).filter(Invoice.id == invoice_id, Invoice.tenant_id == tenant.id).first()
    if inv is None or not inv.source_file_url or not os.path.exists(inv.source_file_url):
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(inv.source_file_url)

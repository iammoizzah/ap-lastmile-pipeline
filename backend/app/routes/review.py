"""
Human-in-the-loop review API.

Rules enforced here (these are the governance story, not UI niceties):
  * Only invoices in `pending_review` can be decided, and only once (409 otherwise).
  * Rejecting always requires a reason.
  * Approving an invoice that still carries a HIGH-severity flag requires a
    written override reason, so exceptions are justified on the record.
  * Every decision writes a before/after audit row in the same transaction.
  * An edit corrects the extracted fields, re-runs matching on the corrected
    values, and then approves. Flags are judged after the correction.
"""
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, field_validator
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.models import AuditLog, Invoice, PurchaseOrder, ReviewDecision
from app.services.audit import invoice_snapshot, log_event
from app.services.matching import decide_route, get_config, normalize_flags, risk_score
from app.services.pipeline import run_matching
from app.services.tenancy import get_demo_tenant

router = APIRouter()

EDITABLE_FIELDS = {"vendor", "date", "total"}


class DecisionRequest(BaseModel):
    action: Literal["approve", "edit", "reject"]
    reason: Optional[str] = None
    edited_fields: Optional[dict] = None
    reviewer: str = "demo-reviewer"

    @field_validator("reason")
    @classmethod
    def strip_reason(cls, v):
        return v.strip() if isinstance(v, str) else v


def _get_invoice(db: Session, tenant_id: str, invoice_id: str) -> Invoice:
    inv = db.query(Invoice).filter(Invoice.id == invoice_id, Invoice.tenant_id == tenant_id).first()
    if inv is None:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return inv


def _queue_item(inv: Invoice, cfg: dict) -> dict:
    flags = normalize_flags(inv.anomaly_flags)
    ext = inv.extraction_confidence or 0.0
    match = inv.match_confidence or 0.0
    return {
        "id": inv.id,
        "status": inv.status,
        "vendor": inv.extracted_vendor,
        "date": inv.extracted_date,
        "total": inv.extracted_total,
        "extraction_confidence": inv.extraction_confidence,
        "match_confidence": inv.match_confidence,
        "route": decide_route(flags, ext, match, cfg),
        "risk_score": risk_score(flags, ext, match),
        "flags": [f.code for f in flags],
        "uploaded_at": inv.uploaded_at.isoformat() if inv.uploaded_at else None,
    }


@router.get("/queue")
def review_queue(
    status: str = Query("pending_review"),
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """Invoices awaiting a decision, riskiest first so reviewers see problems before routine items."""
    tenant = get_demo_tenant(db)
    cfg = get_config(tenant.config)
    invoices = db.query(Invoice).filter(Invoice.tenant_id == tenant.id, Invoice.status == status).all()
    items = [_queue_item(i, cfg) for i in invoices]
    items.sort(key=lambda x: (-x["risk_score"], x["uploaded_at"] or ""))
    return {"count": len(items), "items": items[:limit]}


@router.get("/{invoice_id}")
def review_detail(invoice_id: str, db: Session = Depends(get_db)):
    tenant = get_demo_tenant(db)
    inv = _get_invoice(db, tenant.id, invoice_id)
    cfg = get_config(tenant.config)

    po = None
    if inv.matched_po_id:
        p = db.query(PurchaseOrder).filter(PurchaseOrder.id == inv.matched_po_id).first()
        if p:
            po = {"id": p.id, "po_number": p.po_number, "expected_amount": p.expected_amount,
                  "status": p.status}

    audit = (db.query(AuditLog)
             .filter(AuditLog.tenant_id == tenant.id, AuditLog.entity_type == "invoice",
                     AuditLog.entity_id == inv.id)
             .order_by(AuditLog.created_at).all())

    item = _queue_item(inv, cfg)
    item["flags"] = [f.to_dict() for f in normalize_flags(inv.anomaly_flags)]
    return {
        **item,
        "matched_po": po,
        "file_url": f"/invoices/{inv.id}/file",
        "audit_trail": [
            {"at": a.created_at.isoformat() if a.created_at else None, "actor": a.actor,
             "action": a.action, "before": a.before_state, "after": a.after_state}
            for a in audit
        ],
    }


@router.post("/{invoice_id}/decision")
def decide(invoice_id: str, body: DecisionRequest, db: Session = Depends(get_db)):
    tenant = get_demo_tenant(db)
    inv = _get_invoice(db, tenant.id, invoice_id)

    if inv.status != "pending_review":
        raise HTTPException(status_code=409,
                            detail=f"Invoice is already '{inv.status}' and can't be decided again.")

    if body.action == "reject" and not body.reason:
        raise HTTPException(status_code=422, detail="A reason is required to reject an invoice.")

    before = invoice_snapshot(inv)
    applied_edits = None

    if body.action == "edit":
        edits = body.edited_fields or {}
        unknown = set(edits) - EDITABLE_FIELDS
        if not edits or unknown:
            raise HTTPException(
                status_code=422,
                detail=f"edit needs edited_fields with keys from {sorted(EDITABLE_FIELDS)}"
                       + (f"; unknown: {sorted(unknown)}" if unknown else ""))
        if "vendor" in edits:
            inv.extracted_vendor = str(edits["vendor"]).strip() or None
        if "date" in edits:
            inv.extracted_date = str(edits["date"]).strip() or None
        if "total" in edits:
            try:
                inv.extracted_total = round(float(str(edits["total"]).replace(",", "")), 2)
            except ValueError:
                raise HTTPException(status_code=422, detail="total must be a number")
        applied_edits = edits
        # Judge the corrected values against the system of record, not the stale OCR output.
        run_matching(db, inv, tenant)

    flags = normalize_flags(inv.anomaly_flags)
    high = [f for f in flags if f.severity == "high"]
    if body.action in ("approve", "edit") and high and not body.reason:
        raise HTTPException(
            status_code=422,
            detail="This invoice has high-severity flags "
                   f"({', '.join(f.code for f in high)}). Approving it requires a written "
                   "override reason.")

    inv.status = "rejected" if body.action == "reject" else "approved"

    db.add(ReviewDecision(
        invoice_id=inv.id, reviewer_id=None,  # real user ids arrive with auth
        action=body.action, edited_fields=applied_edits, reason=body.reason))
    after = invoice_snapshot(inv)
    after["decision_reason"] = body.reason
    after["overrode_flags"] = [f.code for f in high] if body.action != "reject" else []
    log_event(
        db, tenant_id=tenant.id, actor=f"reviewer:{body.reviewer}",
        action=f"invoice_{body.action}", entity_type="invoice", entity_id=inv.id,
        before=before, after=after)

    db.commit()
    return {"invoice_id": inv.id, "status": inv.status, "action": body.action,
            "remaining_flags": [f.code for f in flags]}

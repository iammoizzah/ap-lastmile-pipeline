"""
Audit service: append-only record of every AI decision and human override.

Design rules:
  * Never commit here. The caller commits, so the audit row and the state
    change it describes succeed or fail together (no change without a record,
    no record of a change that was rolled back).
  * Rows are only ever inserted. There is deliberately no update/delete helper.
  * `actor` is "system" for AI/pipeline actions, or "reviewer:<name>" for humans.
"""
from typing import Optional

from sqlalchemy.orm import Session

from app.models.models import AuditLog
from app.services.matching import normalize_flags


def log_event(
    db: Session,
    *,
    tenant_id: str,
    actor: str,
    action: str,
    entity_type: str,
    entity_id: str,
    before: Optional[dict] = None,
    after: Optional[dict] = None,
) -> AuditLog:
    entry = AuditLog(
        tenant_id=tenant_id,
        actor=actor,
        action=action,
        entity_type=entity_type,
        entity_id=str(entity_id),
        before_state=before,
        after_state=after,
    )
    db.add(entry)
    return entry


def invoice_snapshot(invoice) -> dict:
    """JSON-safe picture of an invoice's reviewable state, for before/after diffs."""
    return {
        "status": invoice.status,
        "vendor": invoice.extracted_vendor,
        "date": invoice.extracted_date,
        "total": invoice.extracted_total,
        "extraction_confidence": invoice.extraction_confidence,
        "match_confidence": invoice.match_confidence,
        "matched_po_id": invoice.matched_po_id,
        "flags": [f.code for f in normalize_flags(invoice.anomaly_flags)],
    }

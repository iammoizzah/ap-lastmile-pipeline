"""
Pipeline service: loads a tenant's reference data from the DB, runs the
pure matching logic, and writes the outcome back onto the invoice.
Does not commit: the calling route owns the transaction.
"""
from sqlalchemy.orm import Session

from app.models.models import Invoice, PurchaseOrder, Tenant, Vendor
from app.services.matching import MatchResult, evaluate_invoice, get_config


def run_matching(db: Session, invoice: Invoice, tenant: Tenant) -> MatchResult:
    """Evaluate `invoice` against the tenant's vendors/POs/earlier invoices.
    `invoice` must already be flushed so it has an id."""
    vendors = [
        {"id": v.id, "name": v.name, "known_aliases": v.known_aliases or []}
        for v in db.query(Vendor).filter(Vendor.tenant_id == tenant.id).all()
    ]
    pos = [
        {"id": p.id, "po_number": p.po_number, "vendor_id": p.vendor_id,
         "expected_amount": p.expected_amount, "status": p.status}
        for p in db.query(PurchaseOrder).filter(PurchaseOrder.tenant_id == tenant.id).all()
    ]
    others = [
        {"id": i.id, "vendor": i.extracted_vendor, "date": i.extracted_date,
         "total": i.extracted_total}
        for i in db.query(Invoice).filter(
            Invoice.tenant_id == tenant.id,
            Invoice.id != invoice.id,
            Invoice.status != "rejected",
        ).all()
    ]

    result = evaluate_invoice(
        vendor_text=invoice.extracted_vendor,
        date_text=invoice.extracted_date,
        total=invoice.extracted_total,
        extraction_confidence=invoice.extraction_confidence,
        vendors=vendors,
        purchase_orders=pos,
        existing_invoices=others,
        config=get_config(tenant.config),
    )

    invoice.matched_po_id = result.po_id
    invoice.match_confidence = result.match_confidence
    invoice.anomaly_flags = [f.to_dict() for f in result.flags]
    return result

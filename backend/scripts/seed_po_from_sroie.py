"""
Creates vendors and purchase orders from the SROIE ground truth, so the real
scanned receipts have something realistic to be matched against.

Each receipt is assigned to one scenario (deterministic for a given --seed):
  * unknown vendor   : nothing created -> invoice should flag no_vendor_match
  * vendor, no PO    : vendor created, no PO -> invoice should flag no_po_match
  * PO off by +8%    : PO created with the wrong amount -> amount_mismatch
  * clean            : PO created with the exact amount -> should match cleanly

This is synthetic reference data (SROIE has no PO system). Say so in the case
study: the receipts are real, the purchase orders are generated from them.

Usage:
    cd backend
    python3 scripts/seed_po_from_sroie.py
"""
import argparse
import glob
import json
import os
import random
import re
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

RECEIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data", "receipts"))


def parse_amount(value):
    cleaned = re.sub(r"[^\d.]", "", str(value or ""))
    try:
        return round(float(cleaned), 2)
    except ValueError:
        return None


def main(unknown_rate: float, no_po_rate: float, mismatch_rate: float, seed: int):
    # Imported here (not at module top) so editor import-sorting can't move them
    # above the sys.path line.
    from app.database import SessionLocal
    from app.models.models import PurchaseOrder, Tenant, Vendor

    rng = random.Random(seed)
    db = SessionLocal()
    counts = {"unknown_vendor": 0, "vendor_no_po": 0, "po_mismatch": 0, "clean": 0, "skipped": 0}
    try:
        tenant = db.query(Tenant).order_by(Tenant.created_at).first()
        if tenant is None:
            raise SystemExit("No tenant found. Run scripts/init_db.py and scripts/seed.py first.")

        vendors = {v.name.strip().upper(): v
                   for v in db.query(Vendor).filter(Vendor.tenant_id == tenant.id)}
        po_numbers = {p.po_number for p in
                      db.query(PurchaseOrder).filter(PurchaseOrder.tenant_id == tenant.id)}

        paths = sorted(glob.glob(os.path.join(RECEIPTS_DIR, "*.json")))
        if not paths:
            raise SystemExit(f"No receipt JSON files in {RECEIPTS_DIR}. Run download_sroie.py first.")

        for path in paths:
            gt = json.load(open(path))
            entities = gt.get("entities") or {}
            company = (entities.get("company") or "").strip()
            amount = parse_amount(entities.get("total"))
            if not company or amount is None or amount <= 0:
                counts["skipped"] += 1
                continue

            roll = rng.random()
            if roll < unknown_rate:
                counts["unknown_vendor"] += 1
                continue

            key = company.upper()
            vendor = vendors.get(key)
            if vendor is None:
                vendor = Vendor(tenant_id=tenant.id, name=company, known_aliases=[key])
                db.add(vendor)
                db.flush()
                vendors[key] = vendor

            if roll < unknown_rate + no_po_rate:
                counts["vendor_no_po"] += 1
                continue

            po_number = f"PO-{gt.get('key', os.path.basename(path))[-7:]}"
            if po_number in po_numbers:
                continue
            po_amount = amount
            if roll < unknown_rate + no_po_rate + mismatch_rate:
                po_amount = round(amount * 1.08, 2)
                counts["po_mismatch"] += 1
            else:
                counts["clean"] += 1
            db.add(PurchaseOrder(tenant_id=tenant.id, po_number=po_number, vendor_id=vendor.id,
                                 expected_amount=po_amount, status="open"))
            po_numbers.add(po_number)

        db.commit()
        print(f"Seeded reference data for tenant '{tenant.name}' from {len(paths)} receipts:")
        for k, v in counts.items():
            print(f"  {k:15s} {v}")
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--unknown-rate", type=float, default=0.15)
    p.add_argument("--no-po-rate", type=float, default=0.10)
    p.add_argument("--mismatch-rate", type=float, default=0.15)
    p.add_argument("--seed", type=int, default=7)
    a = p.parse_args()
    main(a.unknown_rate, a.no_po_rate, a.mismatch_rate, a.seed)

"""
Seeds a demo tenant with vendors, purchase orders, and synthetic bank
transactions. Bank data is deliberately noisy (fee deductions, date drift,
truncated references) to mimic what real reconciliation looks like —
there's no public real-world bank dataset to use instead (for obvious
privacy reasons), so this stands in for it. Say so plainly in the case study.

Usage:
    cd backend
    python scripts/init_db.py   # run once first
    python scripts/seed.py
"""
import sys
import os
import random
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from faker import Faker
from app.database import SessionLocal
from app.models.models import Tenant, Vendor, PurchaseOrder, BankTransaction

fake = Faker()
random.seed(42)
Faker.seed(42)

NUM_VENDORS = 12
POS_PER_VENDOR = (1, 4)  # random range
NUM_BANK_TXNS = 40


def messy_reference(po_number: str) -> str:
    """Simulate how bank feeds mangle references: truncation, prefixes, case changes."""
    choice = random.random()
    if choice < 0.3:
        return po_number[: random.randint(4, len(po_number) - 1)]  # truncated
    if choice < 0.5:
        return f"PMT-{po_number.lower()}"
    if choice < 0.7:
        return po_number.replace("-", "")
    return po_number  # clean, some are fine


def main():
    db = SessionLocal()
    try:
        tenant = Tenant(
            name="Acme Demo Corp",
            config={"approval_threshold": 0.9, "field_mapping_overrides": {}},
        )
        db.add(tenant)
        db.flush()  # get tenant.id without committing yet

        vendors = []
        for _ in range(NUM_VENDORS):
            company = fake.company()
            v = Vendor(
                tenant_id=tenant.id,
                name=company,
                known_aliases=[company.upper(), company.replace(",", "").replace(".", "")],
            )
            db.add(v)
            vendors.append(v)
        db.flush()

        pos = []
        for v in vendors:
            for i in range(random.randint(*POS_PER_VENDOR)):
                po_number = f"PO-{fake.random_number(digits=5, fix_len=True)}"
                amount = round(random.uniform(150, 15000), 2)
                po = PurchaseOrder(
                    tenant_id=tenant.id,
                    po_number=po_number,
                    vendor_id=v.id,
                    expected_amount=amount,
                    status="open",
                )
                db.add(po)
                pos.append(po)
        db.flush()

        # Bank transactions: some match POs with noise (fees, date drift, mangled refs),
        # some are unrelated real-world noise (bank fees, unrelated deposits).
        batch_id = f"batch-{datetime.now(timezone.utc).strftime('%Y%m%d')}"
        matched_source_pos = random.sample(pos, k=min(NUM_BANK_TXNS - 8, len(pos)))

        for po in matched_source_pos:
            fee = round(random.uniform(0, 12), 2) if random.random() < 0.25 else 0.0
            amount = round(po.expected_amount - fee, 2)
            date_drift = timedelta(days=random.randint(-3, 5))
            txn = BankTransaction(
                tenant_id=tenant.id,
                upload_batch_id=batch_id,
                txn_date=datetime.now(timezone.utc) - timedelta(days=random.randint(1, 30)) + date_drift,
                amount=amount,
                description_raw=f"ACH PMT {po.po_number} {fake.company().upper()}",
                reference_raw=messy_reference(po.po_number),
            )
            db.add(txn)

        # Unrelated noise transactions (bank fees, unmatched deposits)
        for _ in range(8):
            txn = BankTransaction(
                tenant_id=tenant.id,
                upload_batch_id=batch_id,
                txn_date=datetime.now(timezone.utc) - timedelta(days=random.randint(1, 30)),
                amount=round(random.uniform(-50, 500), 2),
                description_raw=random.choice(
                    ["MONTHLY SERVICE FEE", "WIRE FEE", "MISC DEPOSIT", "INTEREST CREDIT"]
                ),
                reference_raw=fake.bothify(text="REF-########"),
            )
            db.add(txn)

        db.commit()
        print(f"Seeded tenant: {tenant.name} ({tenant.id})")
        print(f"  Vendors: {len(vendors)}")
        print(f"  Purchase orders: {len(pos)}")
        print(f"  Bank transactions: {NUM_BANK_TXNS} (batch: {batch_id})")
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


if __name__ == "__main__":
    main()


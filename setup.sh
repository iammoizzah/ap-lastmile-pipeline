#!/usr/bin/env bash
# Run this from inside your cloned repo folder (e.g. ap-lastmile-pipeline/)
set -e

cat > "README.md" << 'SCRIPT_EOF'
# AP Last-Mile Pipeline

Last-mile AI integration for enterprise accounts payable: invoice intake → AI extraction → human-in-the-loop review → mock ERP write-back → bank reconciliation — with multi-tenant config and a full audit trail.

Built as a portfolio project demonstrating Forward Deployed Engineering skills: bridging demo-grade AI with the messy, governed reality of enterprise workflows.

## Why this exists

Manual invoice processing costs enterprises an estimated $10–15 per invoice and ~17 days of cycle time (industry benchmarks, cited in `docs/MVP_SPEC.md`). This project builds a working, narrow slice of what a production AP automation layer looks like — not a chatbot demo, but a pipeline with confidence scoring, human review, audit logging, and reconciliation.

See [`docs/MVP_SPEC.md`](docs/MVP_SPEC.md) for the full spec: user stories, data model, architecture, milestones, and metrics.

## Stack

- **Frontend:** Next.js (Vercel)
- **Backend:** FastAPI (Render)
- **Database:** Postgres (Neon / Supabase)
- **Storage:** Supabase Storage
- **Extraction:** Tesseract OCR + rule-based parsing (optional LLM path, flagged)

Entirely free-tier deployable — no paid infra required.

## Project structure

```
backend/
  app/
    routes/      # FastAPI route handlers
    services/     # extraction, matching, audit logic
    models/       # SQLAlchemy models / Pydantic schemas
  migrations/     # DB migrations
  scripts/        # seed data, dataset download helpers
frontend/
  app/            # Next.js app router pages
  components/     # shared UI components
docs/
  MVP_SPEC.md     # full MVP specification
```

## Status

🚧 In development — see `docs/MVP_SPEC.md` §8 for the milestone roadmap.

## Local setup

```bash
# 1. Start Postgres locally
docker compose up -d

# 2. Set up the Python backend
cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env

# 3. Create tables
python scripts/init_db.py

# 4. Seed demo tenant, vendors, POs, synthetic bank transactions
python scripts/seed.py

# 5. (Optional) download real sample invoice receipts for extraction testing
python scripts/download_sroie.py --n 25

# 6. Run the API
uvicorn app.main:app --reload
# -> http://localhost:8000/health
```

**Milestone 1 status:** DB schema + seed data + sample real receipts. No
extraction, matching, or review endpoints yet — those are Milestones 2-5
(see `docs/MVP_SPEC.md` §8).

SCRIPT_EOF

cat > "docker-compose.yml" << 'SCRIPT_EOF'
services:
  db:
    image: postgres:16-alpine
    container_name: ap_pipeline_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ap_user
      POSTGRES_PASSWORD: ap_pass
      POSTGRES_DB: ap_pipeline
    ports:
      - "5432:5432"
    volumes:
      - ap_pipeline_pgdata:/var/lib/postgresql/data

volumes:
  ap_pipeline_pgdata:

SCRIPT_EOF

cat > ".gitignore" << 'SCRIPT_EOF'
# Python
__pycache__/
*.pyc
.venv/
venv/
*.egg-info/
.pytest_cache/

# Node / Next.js
node_modules/
.next/
out/
.env
.env.local
.env*.local

# OS / editor
.DS_Store
.vscode/
.idea/

# Data (do not commit real uploads, downloaded datasets, or DB dumps)
backend/data/
*.sqlite3
*.db

# Env files with secrets
*.env

SCRIPT_EOF

mkdir -p "frontend/components"
cat > "frontend/components/.gitkeep" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "frontend/app"
cat > "frontend/app/.gitkeep" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "backend"
cat > "backend/requirements.txt" << 'SCRIPT_EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
sqlalchemy==2.0.35
psycopg2-binary==2.9.9
alembic==1.13.2
pydantic==2.9.2
pydantic-settings==2.5.2
python-dotenv==1.0.1
python-multipart==0.0.9
passlib[bcrypt]==1.7.4
pyjwt==2.9.0

# Extraction
pytesseract==0.3.13
Pillow==10.4.0

# Seed / synthetic data
Faker==29.0.0

# Optional: SROIE download (Milestone 1 helper only)
datasets==3.0.1

SCRIPT_EOF

mkdir -p "backend"
cat > "backend/.env.example" << 'SCRIPT_EOF'
# Copy this to backend/.env and fill in as needed
DATABASE_URL=postgresql+psycopg2://ap_user:ap_pass@localhost:5432/ap_pipeline

# Only needed if you enable the optional LLM extraction path later
ANTHROPIC_API_KEY=

# JWT signing secret (generate a real random value before deploying anywhere)
JWT_SECRET=dev-only-change-me

SCRIPT_EOF

mkdir -p "backend/app"
cat > "backend/app/main.py" << 'SCRIPT_EOF'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="AP Last-Mile Pipeline API", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten before deploying anywhere real
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok"}


# Routers get mounted here as milestones add them:
# from app.routes import invoices, reconcile, admin, metrics
# app.include_router(invoices.router, prefix="/invoices", tags=["invoices"])

SCRIPT_EOF

mkdir -p "backend/app"
cat > "backend/app/__init__.py" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "backend/app"
cat > "backend/app/database.py" << 'SCRIPT_EOF'
import os
from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

load_dotenv()

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg2://ap_user:ap_pass@localhost:5432/ap_pipeline",
)

engine = create_engine(DATABASE_URL, echo=False, future=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    """FastAPI dependency: yields a DB session and ensures it's closed."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

SCRIPT_EOF

mkdir -p "backend/app/services"
cat > "backend/app/services/__init__.py" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "backend/app/models"
cat > "backend/app/models/__init__.py" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "backend/app/models"
cat > "backend/app/models/models.py" << 'SCRIPT_EOF'
import uuid
from datetime import datetime

from sqlalchemy import (
    Column, String, Float, DateTime, ForeignKey, JSON, Text, Boolean
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship

from app.database import Base


def gen_uuid():
    return str(uuid.uuid4())


class Tenant(Base):
    __tablename__ = "tenants"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    name = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    # approval_threshold: float 0-1 confidence above which auto-approval is allowed
    # field_mapping_overrides: dict of per-tenant field name remaps
    config = Column(JSON, default=dict)

    users = relationship("User", back_populates="tenant")
    vendors = relationship("Vendor", back_populates="tenant")


class User(Base):
    __tablename__ = "users"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    email = Column(String, unique=True, nullable=False)
    password_hash = Column(String, nullable=False)
    role = Column(String, default="reviewer")  # admin | reviewer
    created_at = Column(DateTime, default=datetime.utcnow)

    tenant = relationship("Tenant", back_populates="users")


class Vendor(Base):
    __tablename__ = "vendors"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    name = Column(String, nullable=False)
    known_aliases = Column(JSON, default=list)

    tenant = relationship("Tenant", back_populates="vendors")
    purchase_orders = relationship("PurchaseOrder", back_populates="vendor")


class PurchaseOrder(Base):
    __tablename__ = "purchase_orders"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    po_number = Column(String, nullable=False)
    vendor_id = Column(UUID(as_uuid=False), ForeignKey("vendors.id"), nullable=False)
    expected_amount = Column(Float, nullable=False)
    status = Column(String, default="open")  # open | matched | closed

    vendor = relationship("Vendor", back_populates="purchase_orders")


class Invoice(Base):
    __tablename__ = "invoices"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    source_file_url = Column(String, nullable=True)
    uploaded_at = Column(DateTime, default=datetime.utcnow)

    extracted_vendor = Column(String, nullable=True)
    extracted_date = Column(String, nullable=True)
    extracted_total = Column(Float, nullable=True)
    extracted_line_items = Column(JSON, default=list)
    extraction_confidence = Column(Float, nullable=True)
    extraction_method = Column(String, default="ocr_rules")  # ocr_rules | llm

    matched_po_id = Column(UUID(as_uuid=False), ForeignKey("purchase_orders.id"), nullable=True)
    match_confidence = Column(Float, nullable=True)
    anomaly_flags = Column(JSON, default=list)  # e.g. ["no_po_match", "amount_mismatch", "duplicate"]

    status = Column(String, default="pending_review")
    # pending_review | approved | rejected | posted


class ReviewDecision(Base):
    __tablename__ = "review_decisions"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    invoice_id = Column(UUID(as_uuid=False), ForeignKey("invoices.id"), nullable=False)
    reviewer_id = Column(UUID(as_uuid=False), ForeignKey("users.id"), nullable=True)
    action = Column(String, nullable=False)  # approve | edit | reject
    edited_fields = Column(JSON, nullable=True)
    reason = Column(Text, nullable=True)
    decided_at = Column(DateTime, default=datetime.utcnow)


class ExpectedPayment(Base):
    __tablename__ = "expected_payments"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    invoice_id = Column(UUID(as_uuid=False), ForeignKey("invoices.id"), nullable=False)
    vendor_id = Column(UUID(as_uuid=False), ForeignKey("vendors.id"), nullable=True)
    amount = Column(Float, nullable=False)
    expected_date = Column(DateTime, nullable=True)
    status = Column(String, default="expected")  # expected | matched | overdue


class BankTransaction(Base):
    __tablename__ = "bank_transactions"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    upload_batch_id = Column(String, nullable=True)
    txn_date = Column(DateTime, nullable=False)
    amount = Column(Float, nullable=False)
    description_raw = Column(String, nullable=True)
    reference_raw = Column(String, nullable=True)


class ReconciliationMatch(Base):
    __tablename__ = "reconciliation_matches"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    bank_transaction_id = Column(UUID(as_uuid=False), ForeignKey("bank_transactions.id"), nullable=False)
    expected_payment_id = Column(UUID(as_uuid=False), ForeignKey("expected_payments.id"), nullable=True)
    match_confidence = Column(Float, nullable=True)
    match_reason = Column(Text, nullable=True)
    status = Column(String, default="suggested")  # suggested | confirmed | rejected
    reviewer_id = Column(UUID(as_uuid=False), ForeignKey("users.id"), nullable=True)
    decided_at = Column(DateTime, nullable=True)


class AuditLog(Base):
    __tablename__ = "audit_log"
    id = Column(UUID(as_uuid=False), primary_key=True, default=gen_uuid)
    tenant_id = Column(UUID(as_uuid=False), ForeignKey("tenants.id"), nullable=False)
    actor = Column(String, nullable=False)  # "system" or a user_id
    action = Column(String, nullable=False)
    entity_type = Column(String, nullable=False)
    entity_id = Column(String, nullable=False)
    before_state = Column(JSON, nullable=True)
    after_state = Column(JSON, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

SCRIPT_EOF

mkdir -p "backend/app/routes"
cat > "backend/app/routes/__init__.py" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "backend/migrations"
cat > "backend/migrations/.gitkeep" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "backend/scripts"
cat > "backend/scripts/init_db.py" << 'SCRIPT_EOF'
"""
Creates all tables defined in app/models/models.py.

MVP uses create_all() for speed. Swap to Alembic migrations before this
goes anywhere near a real environment with data you care about.

Usage:
    cd backend
    python scripts/init_db.py
"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.database import Base, engine
from app.models import models  # noqa: F401  (import registers models with Base)


def main():
    print(f"Creating tables at {engine.url} ...")
    Base.metadata.create_all(bind=engine)
    print("Done. Tables created:")
    for table in Base.metadata.sorted_tables:
        print(f"  - {table.name}")


if __name__ == "__main__":
    main()

SCRIPT_EOF

mkdir -p "backend/scripts"
cat > "backend/scripts/download_sroie.py" << 'SCRIPT_EOF'
"""
Downloads a sample of the SROIE dataset (ICDAR 2019 Robust Reading
Challenge — 973 real scanned receipts with ground-truth company/date/total
annotations) from its Hugging Face mirror, for use as realistic test input
to the invoice extraction pipeline.

Source: https://huggingface.co/datasets/rth/sroie-2019-v2
(mirrors the original ICDAR 2019 SROIE competition data)

Requires: pip install datasets  (already in requirements.txt)

Usage:
    cd backend
    python scripts/download_sroie.py --n 25

Output:
    backend/data/receipts/<id>.jpg
    backend/data/receipts/<id>.json   (ground truth: company, date, total, address)
"""
import argparse
import json
import os

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "receipts")


def main(n: int):
    try:
        from datasets import load_dataset
    except ImportError:
        raise SystemExit(
            "Missing dependency. Run: pip install datasets"
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Loading SROIE sample from Hugging Face (rth/sroie-2019-v2), n={n} ...")
    ds = load_dataset("rth/sroie-2019-v2", split=f"train[:{n}]")

    saved = 0
    for i, row in enumerate(ds):
        try:
            image = row["image"]
            gt_raw = row.get("text", row.get("ground_truth", None))

            img_path = os.path.join(OUT_DIR, f"receipt_{i:04d}.jpg")
            image.convert("RGB").save(img_path)

            gt_path = os.path.join(OUT_DIR, f"receipt_{i:04d}.json")
            with open(gt_path, "w") as f:
                if isinstance(gt_raw, str):
                    try:
                        parsed = json.loads(gt_raw)
                    except json.JSONDecodeError:
                        parsed = {"raw": gt_raw}
                else:
                    parsed = gt_raw or {}
                json.dump(parsed, f, indent=2)

            saved += 1
        except Exception as e:
            print(f"  skipped row {i}: {e}")

    print(f"Saved {saved} receipt images + ground-truth files to {OUT_DIR}")
    print("Note: field names in ground truth vary slightly across dataset "
          "revisions — inspect one .json file before wiring up the extraction "
          "accuracy check in Milestone 2.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=25, help="number of receipts to download")
    args = parser.parse_args()
    main(args.n)

SCRIPT_EOF

mkdir -p "backend/scripts"
cat > "backend/scripts/seed.py" << 'SCRIPT_EOF'
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
from datetime import datetime, timedelta

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
        batch_id = f"batch-{datetime.utcnow().strftime('%Y%m%d')}"
        matched_source_pos = random.sample(pos, k=min(NUM_BANK_TXNS - 8, len(pos)))

        for po in matched_source_pos:
            fee = round(random.uniform(0, 12), 2) if random.random() < 0.25 else 0.0
            amount = round(po.expected_amount - fee, 2)
            date_drift = timedelta(days=random.randint(-3, 5))
            txn = BankTransaction(
                tenant_id=tenant.id,
                upload_batch_id=batch_id,
                txn_date=datetime.utcnow() - timedelta(days=random.randint(1, 30)) + date_drift,
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
                txn_date=datetime.utcnow() - timedelta(days=random.randint(1, 30)),
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

SCRIPT_EOF

mkdir -p "backend/scripts"
cat > "backend/scripts/.gitkeep" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "docs"
cat > "docs/MVP_SPEC.md" << 'SCRIPT_EOF'
# MVP Spec — AP Last-Mile Pipeline
**Last-mile AI integration for enterprise accounts payable: invoice intake → human-reviewed approval → mock ERP write-back → bank reconciliation.**

Status: Draft v1 · Owner: [you] · Target: FDE portfolio project

---

## 1. Problem Statement

Enterprise AP teams lose real money and time to manual, error-prone processes:

- Manual invoice processing costs an estimated **$10–$15 per invoice** (Levvel Research), dropping to **$2–$3 with automation** — a 70%+ reduction.
- Ardent Partners' 2025 research puts the average AP org's cost at **$9.40/invoice**.
- Manual cycle time runs **~17.4 days** vs. **~3 days** for best-in-class automated teams.
- Manual entry error rates run **~2%**, causing downstream payment disputes and reconciliation drag.

The "last mile" isn't the AI model — it's getting extracted, uncertain, AI-generated data safely into a system of record, with a human able to catch what the model gets wrong, and a full audit trail IT can trust.

This project builds a narrow, working slice of that: **invoice → approval → payment record → bank reconciliation**, with human-in-the-loop review, per-tenant configuration, and audit logging throughout.

---

## 2. Goals / Non-Goals

**Goals (MVP):**
- Demonstrate the full extraction → confidence-scoring → HITL review → system write-back → reconciliation loop end to end.
- Multi-tenant data model (no per-client code forks).
- Full audit log of every AI decision and human override.
- Dashboard with real (simulated-but-tracked) throughput/accuracy metrics.
- Deployable for free (Vercel + Render/Fly + Neon/Supabase).

**Non-Goals (explicitly out of scope for MVP):**
- Real ERP/bank integrations (mocked instead — connector interfaces designed to be swappable later).
- Production-grade queueing (Postgres status column stands in for SQS/Redis; noted as a scaling trade-off).
- SSO/enterprise auth (basic email+password or magic link is enough).
- Multi-currency, tax logic, or full accounting rules.

---

## 3. User Stories

- As an **AP reviewer**, I want to see a queue of AI-extracted invoices sorted by confidence/risk, so I can focus my attention on the ones that actually need judgment.
- As an **AP reviewer**, I want to see *why* the AI flagged an invoice (no PO match, amount mismatch, duplicate), so I can decide quickly instead of re-deriving the reasoning myself.
- As an **AP reviewer**, I want to approve, edit, or reject an extracted invoice, and have that decision logged, so there's accountability.
- As an **AP reviewer**, I want unmatched bank transactions surfaced with AI-suggested matches and confidence scores, so reconciliation doesn't mean scanning two spreadsheets by eye.
- As a **finance admin (tenant admin)**, I want to configure approval thresholds and field-mapping rules per tenant, so the same platform works for different client setups without custom code.
- As an **IT/compliance stakeholder**, I want a full audit trail of every AI decision and every human override, so I can trust this running in production.
- As **me (the builder)**, I want a metrics dashboard showing cycle time, auto-approval rate, and estimated $ / time saved vs. the manual baseline, so I have a real outcomes story for the case study.

---

## 4. Non-Functional Requirements

| Area | Requirement |
|---|---|
| Multi-tenancy | Every table scoped by `tenant_id`; no cross-tenant data leakage; config (thresholds, field mappings) stored per tenant |
| Audit logging | Every AI extraction, confidence score, human decision, and system write is appended to an immutable `audit_log` table (who/what/when/before→after) |
| Security | Passwords hashed (bcrypt/argon2); tenant-scoped auth middleware on every API route; file uploads validated by type/size |
| Monitoring | Basic structured logging (extraction latency, match confidence distribution, error counts) exposed on an internal `/health` and `/metrics` endpoint |
| Explainability | Every AI decision (extraction or match) stores a short human-readable reason string, not just a confidence float |
| Reversibility | Human review can always override an AI decision before it's "posted" to the mock ERP; nothing auto-posts above a configurable risk threshold |

---

## 5. Data Model

**Entities:**

```
Tenant
  id, name, created_at, config (jsonb: approval_threshold, field_mapping_overrides)

User
  id, tenant_id, email, password_hash, role (admin | reviewer), created_at

Vendor
  id, tenant_id, name, known_aliases (jsonb)

PurchaseOrder
  id, tenant_id, po_number, vendor_id, expected_amount, status

Invoice
  id, tenant_id, source_file_url, uploaded_at
  extracted_vendor, extracted_date, extracted_total, extracted_line_items (jsonb)
  extraction_confidence, extraction_method (ocr_rules | llm)
  matched_po_id (nullable), match_confidence, anomaly_flags (jsonb array)
  status: pending_review | approved | rejected | posted

ReviewDecision
  id, invoice_id, reviewer_id, action (approve|edit|reject), edited_fields (jsonb, nullable), reason, decided_at

ExpectedPayment
  id, tenant_id, invoice_id, vendor_id, amount, expected_date, status: expected | matched | overdue

BankTransaction
  id, tenant_id, upload_batch_id, txn_date, amount, description_raw, reference_raw

ReconciliationMatch
  id, tenant_id, bank_transaction_id, expected_payment_id (nullable)
  match_confidence, match_reason, status: suggested | confirmed | rejected
  reviewer_id (nullable), decided_at (nullable)

AuditLog
  id, tenant_id, actor (system|user_id), action, entity_type, entity_id,
  before_state (jsonb), after_state (jsonb), created_at
```

**Relationships:** Tenant → (Users, Vendors, POs, Invoices, BankTransactions) 1:many · Invoice → ReviewDecision 1:many · Invoice → ExpectedPayment 1:1 (on approval) · ExpectedPayment ↔ BankTransaction via ReconciliationMatch (1:1 once confirmed).

---

## 6. Architecture (text diagram)

```
[Next.js frontend — Vercel]
   |  (REST/JSON, tenant-scoped JWT)
   v
[FastAPI backend — Render]
   |-- /invoices     (upload, list, review queue, decision)
   |-- /reconcile    (bank CSV upload, suggested matches, confirm)
   |-- /admin        (tenant config, thresholds, field mappings)
   |-- /metrics      (dashboard aggregates)
   |
   |-- Extraction service: Tesseract OCR + rule-based parser (default)
   |                        \-> optional LLM extraction (flagged, rate-limited)
   |-- Matching service: PO matcher (invoice) + reconciliation matcher (bank txns)
   |-- Audit service: writes to audit_log on every state change
   v
[Postgres — Neon/Supabase]   [File storage — Supabase Storage]
   tenant-scoped tables         uploaded receipts / bank CSVs
```

No message queue for MVP — invoice/transaction rows carry a `status` field; the frontend polls/refetches the review queue. Noted as the first thing to swap for a real queue (SQS/Redis + workers) at production scale.

---

## 7. Connector Plan (MVP)

| Connector | MVP implementation | Production equivalent (noted, not built) |
|---|---|---|
| Invoice intake | Manual upload (PDF/image) using SROIE sample receipts + your own test invoices | Email inbox parser, S3 bucket watcher, scanner integration |
| PO/vendor data | Seeded Postgres tables (CSV import script) | Real ERP/procurement API (SAP, NetSuite, etc.) |
| ERP write-back | Mock REST API (`POST /mock-erp/post-invoice`) you build and log | Real ERP API (SAP, Oracle, NetSuite) |
| Bank statement | CSV upload (Faker-generated synthetic data mimicking real messiness) | Bank feed API / SFTP drop (Plaid for business, or direct bank API) |
| Notifications | Optional: log-only or a webhook to a free Slack/Discord channel | Email/Slack/Teams integration |

---

## 8. Milestones

### Milestone 1 — Repo, schema, seed data (this session)
**Objective:** Working repo, DB schema migrated, seed data loaded.
**Tasks:** repo scaffold, Postgres schema/migrations, seed script (vendors, POs, synthetic bank txns via Faker), pull SROIE sample receipts.
**Acceptance:** `docker-compose up` (or local run) gives a running Postgres with seeded tables; can query tenants/vendors/POs.

### Milestone 2 — Invoice ingestion + extraction
**Objective:** Upload a receipt image → get structured extraction with confidence.
**Tasks:** `/invoices` upload endpoint, Tesseract OCR + rule-based field parser, confidence scoring, store Invoice row.
**Acceptance:** Upload a SROIE sample → see extracted vendor/date/total in the DB with a confidence score.

### Milestone 3 — PO matching + review queue
**Objective:** Invoices matched against POs, flagged, and reviewable.
**Tasks:** matching logic (exact + fuzzy vendor/amount match), anomaly flags, `/invoices/queue` + `/invoices/{id}/decision` endpoints, minimal frontend review UI.
**Acceptance:** Can approve/edit/reject an invoice in the UI; decision + reason logged to `audit_log`.

### Milestone 4 — Mock ERP write-back + ExpectedPayment
**Objective:** Approved invoices post to a mock ERP and create an ExpectedPayment.
**Tasks:** mock ERP endpoint, post-on-approval flow, audit logging of the write.
**Acceptance:** Approving an invoice creates a visible "posted" record + an ExpectedPayment row.

### Milestone 5 — Bank reconciliation
**Objective:** Upload bank CSV, get suggested matches against ExpectedPayments, review + confirm.
**Tasks:** CSV upload, fuzzy matcher (amount/date/reference tolerant of fees & drift), `/reconcile` review UI, confirm/reject flow.
**Acceptance:** Upload synthetic bank CSV → see suggested matches with confidence + reason; confirming updates both records.

### Milestone 6 — Metrics dashboard + deploy
**Objective:** Full pipeline demoable end-to-end, deployed, with a metrics view.
**Tasks:** `/metrics` aggregates (cycle time, auto-approval rate, match rate, simulated $ saved vs. baseline), dashboard page, deploy frontend to Vercel + backend to Render + DB to Neon/Supabase.
**Acceptance:** Public URL, can run the full flow live, dashboard shows real numbers from your own seeded run.

---

## 9. Metrics to Track (even if simulated)

- Invoices processed / time period
- Auto-approved vs. escalated-to-human rate
- Avg. extraction confidence, and accuracy vs. SROIE ground truth
- Avg. time from upload → posted (cycle time)
- Reconciliation match rate (auto-confirmed vs. manual)
- Estimated $ and time saved vs. the $10–15/invoice, ~17-day manual baseline cited above

---

## 10. Case Study Structure (for later)

1. **Problem** — the documented cost/time of manual AP processing (with citations)
2. **Constraints** — solo build, zero budget, no real enterprise data access
3. **Solution** — architecture, HITL design, multi-tenant config, audit trail
4. **Outcomes** — your own pipeline's measured numbers against the industry baseline
5. **Lessons** — what you'd change for real production scale (queueing, real connectors, SSO)

---

## 11. Free Stack Summary

Frontend: Next.js on Vercel · Backend: FastAPI on Render · DB: Neon or Supabase Postgres · Storage: Supabase Storage · Extraction: Tesseract + rules (LLM path optional/flagged) · No paid infra required.

SCRIPT_EOF

echo "✅ All files created."
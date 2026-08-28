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

from app.routes import invoices

app = FastAPI(title="AP Last-Mile Pipeline API", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten before deploying anywhere real
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(invoices.router, prefix="/invoices", tags=["invoices"])


@app.get("/health")
def health():
    return {"status": "ok"}


# Additional routers get mounted here as later milestones add them:
# from app.routes import reconcile, admin, metrics
# app.include_router(reconcile.router, prefix="/reconcile", tags=["reconcile"])

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

mkdir -p "backend/app/services"
cat > "backend/app/services/extraction.py" << 'SCRIPT_EOF'
"""
Extraction service: turns a receipt/invoice image into structured fields
(company, date, total) with a confidence score and a stated reason for
each field — not just a black-box number. This is deliberately rule-based
rather than an LLM call: it's boring, cheap, fast, fully explainable, and
gives us a real accuracy baseline to compare an optional LLM path against
later (see extraction_method="llm" on the Invoice model for that hook).

Design note for the case study: routing on confidence, not on "is this
right", is the actual product decision here. A human reviewer should see
*why* something is uncertain (which field, which heuristic failed) rather
than just a float.
"""
import re
from datetime import datetime
from dataclasses import dataclass, field
from typing import Optional

try:
    import pytesseract
    from PIL import Image
except ImportError:
    pytesseract = None
    Image = None


# --- OCR -----------------------------------------------------------------

def run_ocr(image_path: str) -> str:
    """Runs Tesseract OCR on an image file, returns raw text."""
    if pytesseract is None:
        raise RuntimeError(
            "pytesseract/Pillow not installed. Run: python3 -m pip install -r requirements.txt"
        )
    image = Image.open(image_path)
    return pytesseract.image_to_string(image)


# --- Field parsers ---------------------------------------------------------

TOTAL_KEYWORDS = re.compile(
    r"(GRAND\s*TOTAL|TOTAL\s*AMOUNT|AMOUNT\s*DUE|TOTAL\s*DUE|NET\s*TOTAL|^TOTAL)",
    re.IGNORECASE,
)
MONEY_PATTERN = re.compile(r"(?<![\d.])(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})|\d+\.\d{2})(?!\d)")

DATE_PATTERNS = [
    # DD/MM/YYYY or DD-MM-YYYY
    re.compile(r"\b(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b"),
    # YYYY-MM-DD
    re.compile(r"\b(\d{4}-\d{1,2}-\d{1,2})\b"),
    # 15 JAN 2019 / 15 January 2019
    re.compile(
        r"\b(\d{1,2}\s+(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\s+\d{2,4})\b",
        re.IGNORECASE,
    ),
]

COMPANY_SUFFIXES = re.compile(
    r"\b(SDN\s*BHD|ENTERPRISE|TRADING|SERVICES?|STORE|MARKET|SHOP|SUPPLIES|"
    r"RESTAURANT|CAFE|HARDWARE|INDUSTRIES|CORPORATION|CORP|CO\.?\s*LTD|LLC|INC)\b",
    re.IGNORECASE,
)
NOISE_LINE = re.compile(r"^[\W_]*$|COPY|RECEIPT|INVOICE|TAX\s*INVOICE", re.IGNORECASE)


@dataclass
class FieldResult:
    value: Optional[str]
    confidence: float
    reason: str


@dataclass
class ExtractionResult:
    company: FieldResult
    date: FieldResult
    total: FieldResult
    raw_text: str
    anomaly_flags: list = field(default_factory=list)

    @property
    def overall_confidence(self) -> float:
        vals = [self.company.confidence, self.date.confidence, self.total.confidence]
        return round(sum(vals) / len(vals), 3)


def extract_total(lines: list[str]) -> FieldResult:
    # Pass 1: look for an explicit "TOTAL"-style keyword line with a money value
    for line in lines:
        if TOTAL_KEYWORDS.search(line):
            m = MONEY_PATTERN.findall(line)
            if m:
                value = m[-1].replace(",", "")
                return FieldResult(value, 0.9, f"matched keyword line: {line.strip()!r}")

    # Pass 2: fallback — largest money value anywhere in the document
    all_amounts = []
    for line in lines:
        for m in MONEY_PATTERN.findall(line):
            try:
                all_amounts.append(float(m.replace(",", "")))
            except ValueError:
                continue
    if all_amounts:
        value = f"{max(all_amounts):.2f}"
        return FieldResult(value, 0.5, "fallback: largest money value on receipt (no TOTAL keyword found)")

    return FieldResult(None, 0.0, "no money values found")


def extract_date(lines: list[str]) -> FieldResult:
    for line in lines:
        for pattern in DATE_PATTERNS:
            m = pattern.search(line)
            if m:
                return FieldResult(m.group(1), 0.9, f"matched date pattern in line: {line.strip()!r}")
    return FieldResult(None, 0.0, "no date pattern matched")


def extract_company(lines: list[str]) -> FieldResult:
    candidates = [l for l in lines[:8] if l.strip() and not NOISE_LINE.match(l.strip())]

    # Pass 1: a line with a company-like suffix (SDN BHD, ENTERPRISE, etc.)
    for line in candidates:
        if COMPANY_SUFFIXES.search(line):
            return FieldResult(line.strip(), 0.8, f"matched company-suffix pattern: {line.strip()!r}")

    # Pass 2: fallback — first substantial all-caps-ish line near the top
    for line in candidates:
        letters = re.sub(r"[^A-Za-z]", "", line)
        if len(letters) >= 5 and letters.isupper():
            return FieldResult(line.strip(), 0.4, "fallback: first substantial uppercase line near top")

    return FieldResult(None, 0.0, "no plausible company line found in top of receipt")


def extract_fields(raw_text: str) -> ExtractionResult:
    lines = [l for l in raw_text.splitlines() if l.strip()]

    company = extract_company(lines)
    date = extract_date(lines)
    total = extract_total(lines)

    anomalies = []
    if company.value is None:
        anomalies.append("no_company_match")
    if date.value is None:
        anomalies.append("no_date_match")
    if total.value is None:
        anomalies.append("no_total_match")

    return ExtractionResult(company=company, date=date, total=total, raw_text=raw_text, anomaly_flags=anomalies)


def extract_from_image(image_path: str) -> ExtractionResult:
    raw_text = run_ocr(image_path)
    return extract_fields(raw_text)

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

mkdir -p "backend/app/routes"
cat > "backend/app/routes/invoices.py" << 'SCRIPT_EOF'
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
Challenge — real scanned receipts with ground-truth key-info annotations:
company, date, address, total) from its Hugging Face mirror, for use as
realistic test input to the invoice extraction pipeline.

Source: https://huggingface.co/datasets/jsdnrs/ICDAR2019-SROIE
(corrected/extended version of the original ICDAR 2019 SROIE Task 3 data;
confirmed schema: image, key, image_size, entities{company,date,address,total},
words, bboxes)

Requires: pip install datasets  (already in requirements.txt)

Usage:
    cd backend
    python scripts/download_sroie.py --n 25

Output:
    backend/data/receipts/<key>.jpg
    backend/data/receipts/<key>.json   (ground truth: company, date, total,
                                         address, plus raw OCR words/bboxes
                                         for later line-level matching)
"""
import argparse
import json
import os

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "receipts")


def main(n: int, split: str):
    try:
        from datasets import load_dataset
    except ImportError:
        raise SystemExit(
            "Missing dependency. Run: python3 -m pip install -r requirements.txt"
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"Loading SROIE sample from Hugging Face (jsdnrs/ICDAR2019-SROIE), "
          f"split={split}, n={n} ...")
    ds = load_dataset("jsdnrs/ICDAR2019-SROIE", split=f"{split}[:{n}]")

    saved = 0
    for row in ds:
        try:
            key = row["key"]
            image = row["image"]

            img_path = os.path.join(OUT_DIR, f"{key}.jpg")
            image.convert("RGB").save(img_path)

            gt_path = os.path.join(OUT_DIR, f"{key}.json")
            ground_truth = {
                "key": key,
                "entities": row.get("entities", {}),
                "words": row.get("words", []),
                "bboxes": row.get("bboxes", []),
            }
            with open(gt_path, "w") as f:
                json.dump(ground_truth, f, indent=2)

            saved += 1
        except Exception as e:
            print(f"  skipped {row.get('key', '?')}: {e}")

    print(f"Saved {saved} receipt images + ground-truth files to {OUT_DIR}")
    if saved:
        sample_key = json.load(open(os.path.join(OUT_DIR, f"{ds[0]['key']}.json")))
        print("Sample entities from first receipt:", sample_key["entities"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=25, help="number of receipts to download")
    parser.add_argument("--split", type=str, default="test", choices=["train", "test"],
                         help="which SROIE split to pull from (default: test, 361 receipts)")
    args = parser.parse_args()
    main(args.n, args.split)

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

SCRIPT_EOF

mkdir -p "backend/scripts"
cat > "backend/scripts/.gitkeep" << 'SCRIPT_EOF'

SCRIPT_EOF

mkdir -p "backend/scripts"
cat > "backend/scripts/eval_extraction.py" << 'SCRIPT_EOF'
"""
Runs the extraction service against every downloaded SROIE receipt and
scores it against the real ground truth (company/date/total) — giving you
an actual, citable accuracy number for the case study instead of a guess.

Usage:
    cd backend
    python scripts/eval_extraction.py
"""
import sys
import os
import json
import re
import glob
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.services.extraction import extract_from_image

RECEIPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "receipts")


def normalize_text(s: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", s.upper()) if s else ""


def normalize_amount(s: str):
    try:
        return round(float(str(s).replace(",", "").replace("RM", "").strip()), 2)
    except (ValueError, TypeError):
        return None


DATE_FORMATS = [
    "%d/%m/%Y", "%d-%m-%Y", "%Y-%m-%d", "%d/%m/%y", "%d-%m-%y",
    "%d %b %Y", "%d %B %Y",
]


def normalize_date(s: str):
    if not s:
        return None
    s = s.strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            continue
    return s.upper()  # fall back to raw comparison if unparseable


def company_match(extracted: str, truth: str) -> bool:
    if not extracted or not truth:
        return False
    e, t = normalize_text(extracted), normalize_text(truth)
    return e in t or t in e  # substring match — receipts often extract a partial name


def main():
    image_paths = sorted(glob.glob(os.path.join(RECEIPTS_DIR, "*.jpg")))
    if not image_paths:
        print(f"No receipts found in {RECEIPTS_DIR}. Run scripts/download_sroie.py first.")
        return

    total = len(image_paths)
    correct = {"company": 0, "date": 0, "total": 0}
    field_attempted = {"company": 0, "date": 0, "total": 0}
    confidences = []
    rows = []

    for img_path in image_paths:
        key = os.path.splitext(os.path.basename(img_path))[0]
        gt_path = os.path.join(RECEIPTS_DIR, f"{key}.json")
        if not os.path.exists(gt_path):
            continue
        gt = json.load(open(gt_path))["entities"]

        result = extract_from_image(img_path)
        confidences.append(result.overall_confidence)

        c_ok = company_match(result.company.value, gt.get("company"))
        d_ok = normalize_date(result.date.value) == normalize_date(gt.get("date"))
        t_ok = normalize_amount(result.total.value) == normalize_amount(gt.get("total"))

        for field_name, ok, extracted in [
            ("company", c_ok, result.company.value),
            ("date", d_ok, result.date.value),
            ("total", t_ok, result.total.value),
        ]:
            if extracted is not None:
                field_attempted[field_name] += 1
            if ok:
                correct[field_name] += 1

        rows.append({
            "key": key,
            "company_ok": c_ok, "date_ok": d_ok, "total_ok": t_ok,
            "confidence": result.overall_confidence,
        })

    print(f"\n=== Extraction accuracy over {total} real SROIE receipts ===\n")
    for f in ["company", "date", "total"]:
        acc = correct[f] / total * 100
        precision = (correct[f] / field_attempted[f] * 100) if field_attempted[f] else 0
        print(f"  {f:10s}  accuracy: {acc:5.1f}%   "
              f"(precision when attempted: {precision:5.1f}%, "
              f"attempted {field_attempted[f]}/{total})")

    overall = sum(correct.values()) / (total * 3) * 100
    avg_conf = sum(confidences) / len(confidences) if confidences else 0
    print(f"\n  Overall field accuracy: {overall:.1f}%")
    print(f"  Average confidence score: {avg_conf:.2f}")

    # Confidence calibration check: are low-confidence extractions actually
    # more often wrong? This is the number that matters most for the HITL
    # story — it justifies routing low-confidence items to human review.
    low_conf_rows = [r for r in rows if r["confidence"] < 0.7]
    if low_conf_rows:
        low_conf_wrong = sum(
            1 for r in low_conf_rows if not (r["company_ok"] and r["date_ok"] and r["total_ok"])
        )
        print(f"\n  Low-confidence (<0.7) receipts: {len(low_conf_rows)}/{total}")
        print(f"  Of those, fully-wrong-somewhere: {low_conf_wrong}/{len(low_conf_rows)} "
              f"({low_conf_wrong/len(low_conf_rows)*100:.0f}%) — this is the routing signal HITL relies on")

    out_path = os.path.join(os.path.dirname(__file__), "..", "data", "extraction_eval_report.json")
    with open(out_path, "w") as f:
        json.dump({"total": total, "correct": correct, "field_attempted": field_attempted,
                    "overall_accuracy_pct": overall, "avg_confidence": avg_conf, "rows": rows}, f, indent=2, default=str)
    print(f"\nFull report saved to {out_path}")


if __name__ == "__main__":
    main()

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

echo "✅ All files created/updated."
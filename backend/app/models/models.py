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


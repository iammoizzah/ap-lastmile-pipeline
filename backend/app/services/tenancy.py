"""
Tenant resolution. MVP shortcut: every request acts as the first seeded
tenant. Real auth (JWT carrying tenant_id) replaces this later; every query
already filters by tenant_id, so the swap only touches this one function.
"""
from fastapi import HTTPException
from sqlalchemy.orm import Session

from app.models.models import Tenant


def get_demo_tenant(db: Session) -> Tenant:
    tenant = db.query(Tenant).order_by(Tenant.created_at).first()
    if tenant is None:
        raise HTTPException(status_code=400, detail="No tenant found. Run scripts/seed.py first.")
    return tenant

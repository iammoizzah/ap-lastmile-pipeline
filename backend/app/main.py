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


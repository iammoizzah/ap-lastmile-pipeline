from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routes import invoices, review

app = FastAPI(title="AP Last-Mile Pipeline API", version="0.3.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten before deploying anywhere real
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(invoices.router, prefix="/invoices", tags=["invoices"])
app.include_router(review.router, prefix="/review", tags=["review"])


@app.get("/health")
def health():
    return {"status": "ok"}


# Later milestones mount their routers here:
# from app.routes import erp, reconcile, metrics
# app.include_router(reconcile.router, prefix="/reconcile", tags=["reconcile"])

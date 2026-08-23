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


# AP Last-Mile Pipeline


An integration layer that makes AI safe to use inside real accounts payable workflows. It extracts invoice data with OCR, scores its own confidence, routes uncertain items to a human reviewer, writes only approved results to a mock ERP, and reconciles payments against bank statements, with an audit log of every decision.

**Why it exists:**
manual invoice processing costs an estimated $10-15 per invoice and ~17 days of cycle time. The model reading the invoice is the easy part. The hard part is the last mile: governance, legacy-system write-back, and per-customer configuration.

Built as a portfolio project demonstrating Forward Deployed Engineering skills: bridging demo-grade AI with the messy, governed reality of enterprise workflows.

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

 In development — see `docs/MVP_SPEC.md` §8 for the milestone roadmap.

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


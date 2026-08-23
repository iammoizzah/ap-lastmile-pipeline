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

_Coming in Milestone 1 — backend/DB scaffold and seed script._

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


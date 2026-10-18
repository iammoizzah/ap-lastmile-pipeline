#!/usr/bin/env bash
# Writes the Next.js review screen into frontend/. Run from the REPO ROOT.
# Then:  cd frontend && npm install && npm run dev   (API must be running on :8000)
set -e
if [ ! -d backend/app ]; then echo "Run this from the repo root (folder containing backend/)."; exit 1; fi
mkdir -p frontend/app frontend/components frontend/lib
rm -f frontend/app/.gitkeep frontend/components/.gitkeep

cat > frontend/package.json << 'FE_EOF'
{
  "name": "ap-review-ui",
  "version": "0.1.0",
  "private": true,
  "scripts": { "dev": "next dev", "build": "next build", "start": "next start" },
  "dependencies": { "next": "^14.2.0", "react": "^18.3.1", "react-dom": "^18.3.1" },
  "devDependencies": {
    "@types/node": "^20", "@types/react": "^18", "@types/react-dom": "^18", "typescript": "^5"
  }
}
FE_EOF

cat > frontend/tsconfig.json << 'FE_EOF'
{
  "compilerOptions": {
    "target": "es2017", "lib": ["dom", "dom.iterable", "esnext"], "allowJs": true,
    "skipLibCheck": true, "strict": true, "noEmit": true, "esModuleInterop": true,
    "module": "esnext", "moduleResolution": "bundler", "resolveJsonModule": true,
    "isolatedModules": true, "jsx": "preserve", "incremental": true,
    "plugins": [{ "name": "next" }]
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
FE_EOF

cat > frontend/next.config.js << 'FE_EOF'
/** @type {import('next').NextConfig} */
module.exports = { eslint: { ignoreDuringBuilds: true } };
FE_EOF

cat > frontend/.env.example << 'FE_EOF'
# Copy to .env.local if your API is not on localhost:8000
NEXT_PUBLIC_API_URL=http://localhost:8000
FE_EOF

cat > frontend/lib/api.ts << 'FE_EOF'
export const API = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

export type Severity = "high" | "medium" | "low";
export interface Flag { code: string; reason: string; severity: Severity }
export interface QueueItem {
  id: string; status: string; vendor: string | null; date: string | null; total: number | null;
  extraction_confidence: number | null; match_confidence: number | null;
  route: "fast_track" | "review"; risk_score: number; flags: string[]; uploaded_at: string | null;
}
export interface AuditEntry {
  at: string | null; actor: string; action: string;
  before: Record<string, unknown> | null; after: Record<string, unknown> | null;
}
export interface Detail extends Omit<QueueItem, "flags"> {
  flags: Flag[];
  matched_po: { id: string; po_number: string; expected_amount: number; status: string } | null;
  audit_trail: AuditEntry[];
}
export interface DecisionBody {
  action: "approve" | "edit" | "reject"; reason?: string; reviewer: string;
  edited_fields?: { vendor: string; date: string; total: string };
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${API}${path}`, { cache: "no-store", ...init });
  } catch {
    throw new Error(`Can't reach the API at ${API}. Start it with: uvicorn app.main:app --reload`);
  }
  if (!res.ok) {
    let detail = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      if (typeof body.detail === "string") detail = body.detail;
      else if (Array.isArray(body.detail)) detail = body.detail.map((d: { msg: string }) => d.msg).join("; ");
    } catch { /* keep the generic message */ }
    throw new Error(detail);
  }
  return res.json() as Promise<T>;
}

export const getQueue = (status: string) =>
  request<{ count: number; items: QueueItem[] }>(`/review/queue?status=${status}&limit=200`);
export const getDetail = (id: string) => request<Detail>(`/review/${id}`);
export const decide = (id: string, body: DecisionBody) =>
  request<{ invoice_id: string; status: string; action: string; remaining_flags: string[] }>(
    `/review/${id}/decision`,
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
export const fileUrl = (id: string) => `${API}/invoices/${id}/file`;
export const money = (n: number | null) =>
  n === null ? "—" : n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
FE_EOF

cat > frontend/app/layout.tsx << 'FE_EOF'
import "./globals.css";
import type { ReactNode } from "react";

export const metadata = { title: "Invoice review", description: "Human review queue for AI-extracted invoices" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
FE_EOF

cat > frontend/app/page.tsx << 'FE_EOF'
"use client";
import { useCallback, useEffect, useState } from "react";
import { getQueue, QueueItem } from "../lib/api";
import QueueList from "../components/QueueList";
import InvoiceDetail from "../components/InvoiceDetail";

const TABS = [
  { key: "pending_review", label: "Needs review" },
  { key: "approved", label: "Approved" },
  { key: "rejected", label: "Rejected" },
];

export default function Home() {
  const [tab, setTab] = useState("pending_review");
  const [items, setItems] = useState<QueueItem[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async (preferId?: string | null) => {
    setLoading(true);
    try {
      const q = await getQueue(tab);
      setItems(q.items);
      setError(null);
      setSelected((prev) => {
        const want = preferId ?? prev;
        return want && q.items.some((i) => i.id === want) ? want : q.items[0]?.id ?? null;
      });
    } catch (e) {
      setError((e as Error).message);
      setItems([]);
      setSelected(null);
    } finally {
      setLoading(false);
    }
  }, [tab]);

  useEffect(() => { load(); }, [load]);

  async function onDecided(id: string, message: string) {
    const idx = items.findIndex((i) => i.id === id);
    const next = items[idx + 1]?.id ?? items[idx - 1]?.id ?? null;
    setNotice(message);
    await load(next);
  }

  return (
    <div className="shell">
      <header className="top">
        <h1>Invoice review</h1>
        <nav className="tabs" aria-label="Queue">
          {TABS.map((t) => (
            <button key={t.key} className={t.key === tab ? "tab on" : "tab"}
              onClick={() => { setTab(t.key); setNotice(null); }}>
              {t.label}
            </button>
          ))}
        </nav>
        <span className="count">{items.length} in this list</span>
      </header>
      {error && <div className="banner bad" role="alert">{error}</div>}
      {notice && <div className="banner good" role="status" onClick={() => setNotice(null)}>{notice}</div>}
      <main className="split">
        <QueueList items={items} selected={selected} loading={loading} onSelect={setSelected} />
        {selected
          ? <InvoiceDetail key={selected} id={selected} onDecided={onDecided} />
          : <section className="empty"><p>{loading ? "Loading…" : "No invoices in this list. Upload some with scripts/batch_ingest.py."}</p></section>}
      </main>
    </div>
  );
}
FE_EOF

cat > frontend/components/QueueList.tsx << 'FE_EOF'
import { QueueItem, money } from "../lib/api";

interface Props { items: QueueItem[]; selected: string | null; loading: boolean; onSelect: (id: string) => void }

export default function QueueList({ items, selected, loading, onSelect }: Props) {
  if (items.length === 0) {
    return <aside className="queue"><p className="muted pad">{loading ? "Loading…" : "Nothing here."}</p></aside>;
  }
  return (
    <aside className="queue" aria-label="Invoices">
      <ul>
        {items.map((i) => (
          <li key={i.id}>
            <button className={i.id === selected ? "row on" : "row"} onClick={() => onSelect(i.id)}>
              <span className="row-main">
                <span className="vendor">{i.vendor ?? "Vendor not found"}</span>
                <span className="amount">{money(i.total)}</span>
              </span>
              <span className="row-meta">
                <span className={i.route === "fast_track" ? "pill good" : "pill"}>
                  {i.route === "fast_track" ? "Fast track" : "Review"}
                </span>
                {i.flags.length > 0 && <span className="muted">{i.flags.length} {i.flags.length === 1 ? "flag" : "flags"}</span>}
                <span className="risk" title={`Risk ${Math.round(i.risk_score * 100)}%`}>
                  <i style={{ width: `${Math.max(4, Math.round(i.risk_score * 100))}%` }} />
                </span>
              </span>
            </button>
          </li>
        ))}
      </ul>
    </aside>
  );
}
FE_EOF

cat > frontend/components/InvoiceDetail.tsx << 'FE_EOF'
"use client";
import { useEffect, useState } from "react";
import { Detail, decide, fileUrl, getDetail, money } from "../lib/api";

type FieldInfo = { value: string | null; confidence: number; reason: string };
const pct = (n: number | null) => (n === null ? "—" : `${Math.round(n * 100)}%`);
const label = (action: string) => action.replace("invoice_", "").replace(/_/g, " ");

export default function InvoiceDetail({ id, onDecided }: { id: string; onDecided: (id: string, msg: string) => void }) {
  const [d, setD] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [edits, setEdits] = useState({ vendor: "", date: "", total: "" });
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    getDetail(id)
      .then((x) => {
        setD(x);
        setEdits({ vendor: x.vendor ?? "", date: x.date ?? "", total: x.total === null ? "" : String(x.total) });
      })
      .catch((e: Error) => setError(e.message));
  }, [id]);

  if (!d) {
    return <section className="detail">{error ? <div className="banner bad">{error}</div> : <p className="muted pad">Loading…</p>}</section>;
  }

  const pending = d.status === "pending_review";
  const high = d.flags.filter((f) => f.severity === "high");
  const extraction = d.audit_trail.find((a) => a.action === "invoice_extracted")?.after as Record<string, FieldInfo> | undefined;
  const reasonMissing = reason.trim() === "";

  async function submit(action: "approve" | "edit" | "reject") {
    setBusy(true);
    setError(null);
    try {
      const r = await decide(id, {
        action, reviewer: "demo-reviewer", reason: reason.trim() || undefined,
        edited_fields: action === "edit" ? edits : undefined,
      });
      const verb = action === "reject" ? "Rejected" : action === "edit" ? "Corrected and approved" : "Approved";
      onDecided(id, `${verb}${r.remaining_flags.length > 0 && action !== "reject" ? " with an override" : ""}.`);
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  }

  const rows: { key: "vendor" | "date" | "total"; name: string; shown: string }[] = [
    { key: "vendor", name: "Vendor", shown: d.vendor ?? "—" },
    { key: "date", name: "Date", shown: d.date ?? "—" },
    { key: "total", name: "Total", shown: money(d.total) },
  ];

  return (
    <section className="detail">
      <div className="desk">
        <img src={fileUrl(d.id)} alt="Original receipt" />
      </div>

      <div className="panel">
        <h2 className="title">{d.vendor ?? "Vendor not found"}</h2>
        <p className="muted">
          Extraction {pct(d.extraction_confidence)} sure. PO match {pct(d.match_confidence)}.
          {d.route === "fast_track" ? " Eligible for fast track." : ""}
        </p>

        <h3>What the system read</h3>
        <dl className="fields">
          {rows.map((r) => (
            <div key={r.key} className="field">
              <dt>{r.name}</dt>
              <dd>
                {editing
                  ? <input value={edits[r.key]} onChange={(e) => setEdits({ ...edits, [r.key]: e.target.value })} aria-label={r.name} />
                  : <span className={r.key === "total" ? "amount big" : ""}>{r.shown}</span>}
                {extraction?.[r.key] && <small>{extraction[r.key].reason}</small>}
              </dd>
            </div>
          ))}
        </dl>

        <h3>Purchase order</h3>
        <p>{d.matched_po
          ? `${d.matched_po.po_number}, expected ${money(d.matched_po.expected_amount)}`
          : "No purchase order matched."}</p>

        <h3>{d.flags.length > 0 ? `Why this needs a look (${d.flags.length})` : "No problems found"}</h3>
        <ul className="flags">
          {d.flags.map((f) => (
            <li key={f.code} className={`flag ${f.severity}`}>
              <strong>{f.code.replace(/_/g, " ")}</strong>
              <span>{f.reason}</span>
            </li>
          ))}
        </ul>

        {pending ? (
          <div className="decide">
            <label htmlFor="reason">
              {high.length > 0
                ? "Reason (required to approve, because of the high-severity flags above)"
                : "Reason (required to reject, optional otherwise)"}
            </label>
            <textarea id="reason" rows={3} value={reason} onChange={(e) => setReason(e.target.value)} />
            {error && <div className="banner bad" role="alert">{error}</div>}
            <div className="buttons">
              {editing ? (
                <>
                  <button className="primary" disabled={busy} onClick={() => submit("edit")}>Save correction and approve</button>
                  <button disabled={busy} onClick={() => setEditing(false)}>Cancel</button>
                </>
              ) : (
                <>
                  <button className="primary" disabled={busy || (high.length > 0 && reasonMissing)} onClick={() => submit("approve")}>Approve</button>
                  <button disabled={busy} onClick={() => setEditing(true)}>Correct fields</button>
                  <button className="danger" disabled={busy || reasonMissing} onClick={() => submit("reject")}>Reject</button>
                </>
              )}
            </div>
          </div>
        ) : (
          <p className="pill">{d.status}</p>
        )}

        <details className="history">
          <summary>History ({d.audit_trail.length})</summary>
          <ol>
            {d.audit_trail.map((a, i) => {
              const why = (a.after as { decision_reason?: string } | null)?.decision_reason;
              return (
                <li key={i}>
                  <strong>{label(a.action)}</strong> by {a.actor}
                  <small>{a.at ? new Date(a.at).toLocaleString() : ""}</small>
                  {why && <em>“{why}”</em>}
                </li>
              );
            })}
          </ol>
        </details>
      </div>
    </section>
  );
}
FE_EOF

cat > frontend/app/globals.css << 'FE_EOF'
:root {
  --paper: #f3f5f7; --surface: #ffffff; --ink: #12202c; --muted: #5b6a76; --line: #d6dde3;
  --desk: #1d2a35; --accent: #0e6f7a; --accent-ink: #ffffff;
  --high: #b42318; --high-bg: #fdeceb; --med: #8f5200; --med-bg: #fdf3dc; --low: #4c5a65; --low-bg: #eaeef1;
  --good: #17653a; --good-bg: #e2f3e8;
  --serif: "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; }
body { background: var(--paper); color: var(--ink); font: 15px/1.5 var(--sans); }
button, input, textarea { font: inherit; color: inherit; }
button:focus-visible, input:focus-visible, textarea:focus-visible, summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.muted { color: var(--muted); } .pad { padding: 16px; }

.shell { display: flex; flex-direction: column; height: 100vh; }
.top { display: flex; align-items: center; gap: 24px; padding: 12px 20px; background: var(--surface); border-bottom: 1px solid var(--line); }
.top h1 { margin: 0; font: 600 22px var(--serif); }
.count { margin-left: auto; color: var(--muted); font-size: 13px; }
.tabs { display: flex; gap: 4px; }
.tab { border: 0; background: none; padding: 6px 12px; border-radius: 6px; cursor: pointer; color: var(--muted); }
.tab.on { background: var(--ink); color: #fff; }
.banner { margin: 8px 20px 0; padding: 10px 14px; border-radius: 6px; }
.banner.bad { background: var(--high-bg); color: var(--high); } .banner.good { background: var(--good-bg); color: var(--good); cursor: pointer; }

.split { flex: 1; display: grid; grid-template-columns: 330px minmax(0, 1fr); min-height: 0; }
.queue { overflow-y: auto; border-right: 1px solid var(--line); background: var(--surface); }
.queue ul { list-style: none; margin: 0; padding: 0; }
.row { display: block; width: 100%; text-align: left; padding: 12px 16px; border: 0; border-bottom: 1px solid var(--line); background: none; cursor: pointer; }
.row:hover { background: var(--paper); } .row.on { background: #e3eff1; box-shadow: inset 3px 0 0 var(--accent); }
.row-main { display: flex; justify-content: space-between; gap: 12px; }
.vendor { font-family: var(--serif); font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.amount { font-variant-numeric: tabular-nums; white-space: nowrap; }
.row-meta { display: flex; align-items: center; gap: 10px; margin-top: 6px; font-size: 13px; }
.risk { flex: 1; height: 4px; background: var(--low-bg); border-radius: 2px; overflow: hidden; }
.risk i { display: block; height: 100%; background: var(--high); }
.pill { display: inline-block; padding: 1px 8px; border-radius: 10px; background: var(--low-bg); color: var(--low); font-size: 12px; }
.pill.good { background: var(--good-bg); color: var(--good); }

.empty { display: grid; place-items: center; color: var(--muted); padding: 24px; text-align: center; }
.detail { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(340px, 440px); min-height: 0; }
.desk { background: var(--desk); overflow: auto; padding: 24px; display: flex; justify-content: center; align-items: flex-start; }
.desk img { max-width: 100%; height: auto; box-shadow: 0 6px 24px rgba(0,0,0,.45); background: #fff; }
.panel { overflow-y: auto; padding: 20px 24px 40px; background: var(--surface); }
.title { margin: 0 0 4px; font: 600 26px/1.2 var(--serif); }
.panel h3 { margin: 22px 0 6px; font-size: 14px; font-weight: 600; }
.fields { margin: 0; }
.field { display: grid; grid-template-columns: 70px 1fr; gap: 8px; padding: 8px 0; border-bottom: 1px solid var(--line); }
.field dt { color: var(--muted); } .field dd { margin: 0; display: flex; flex-direction: column; gap: 2px; }
.field small { color: var(--muted); font-size: 12px; }
.amount.big { font: 600 22px var(--sans); font-variant-numeric: tabular-nums; }
.field input { width: 100%; padding: 6px 8px; border: 1px solid var(--line); border-radius: 6px; }
.flags { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.flag { padding: 8px 12px; border-radius: 6px; border-left: 4px solid; display: flex; flex-direction: column; text-transform: none; }
.flag.high { background: var(--high-bg); border-color: var(--high); } .flag.medium { background: var(--med-bg); border-color: var(--med); } .flag.low { background: var(--low-bg); border-color: var(--low); }
.flag strong { text-transform: capitalize; } .flag span { font-size: 13px; }
.decide { margin-top: 24px; display: grid; gap: 8px; }
.decide label { font-size: 13px; color: var(--muted); }
.decide textarea { width: 100%; padding: 8px; border: 1px solid var(--line); border-radius: 6px; resize: vertical; }
.buttons { display: flex; gap: 8px; flex-wrap: wrap; }
.buttons button { padding: 8px 14px; border: 1px solid var(--line); border-radius: 6px; background: var(--surface); cursor: pointer; }
.buttons .primary { background: var(--accent); color: var(--accent-ink); border-color: var(--accent); }
.buttons .danger { color: var(--high); border-color: var(--high); }
.buttons button:disabled { opacity: .45; cursor: not-allowed; }
.history { margin-top: 24px; } .history summary { cursor: pointer; font-weight: 600; font-size: 14px; }
.history ol { margin: 8px 0 0; padding-left: 18px; } .history li { margin-bottom: 8px; }
.history small { display: block; color: var(--muted); } .history em { display: block; }

@media (max-width: 900px) {
  .shell { height: auto; } .split, .detail { grid-template-columns: 1fr; }
  .queue { max-height: 40vh; border-right: 0; border-bottom: 1px solid var(--line); }
  .desk { max-height: 60vh; }
}
FE_EOF

echo "Frontend written. Next: cd frontend && npm install && npm run dev"

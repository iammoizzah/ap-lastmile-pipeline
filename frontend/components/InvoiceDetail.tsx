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

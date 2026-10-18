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

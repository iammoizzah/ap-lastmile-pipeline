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

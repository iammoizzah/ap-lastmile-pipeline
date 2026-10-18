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

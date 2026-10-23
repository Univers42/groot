// --spike: one record per table, collection and page kind, taken from the full dataset (the
// same objects, so the same ids and bytes) around the Hôtel Varenne story. SQL rows are closed
// over their foreign keys so the spike file loads alone; references from documents and pages
// to records outside the spike are left for the full run and counted in stats.json.
import { TABLES } from './tables.mjs';
import { HUB_BOOK } from './library.mjs';
import { HOME, SHARED } from './pages.mjs';

const SPIKE_NOTE = 'note-supply-chain-strategy-01';
const SPIKE_DECISION = 'decision-supplier-switch';

function pickOrder(full, varenneId) {
  const invoiced = new Set(full.tables.trade_invoices.map((i) => i.order_id));
  const lineCount = new Map();
  for (const l of full.tables.trade_order_lines) lineCount.set(l.order_id, (lineCount.get(l.order_id) || 0) + 1);
  const shippedLines = new Set(full.tables.trade_stock_movements.filter((m) => m.kind === 'shipment').map((m) => m.order_line_id));
  const candidates = full.tables.trade_orders.filter((o) => o.company_id === varenneId && invoiced.has(o.id) && !o.deal_id
    && full.tables.trade_order_lines.some((l) => l.order_id === o.id && shippedLines.has(l.id)));
  return candidates.reduce((best, o) => (lineCount.get(o.id) < lineCount.get(best.id) ? o : best));
}

function seedPicks(full) {
  const t = full.tables;
  const varenne = t.companies.find((c) => c.name === 'Hôtel Varenne');
  const marc = t.contacts.find((c) => c.email.startsWith('marc.delorme@'));
  const order = pickOrder(full, varenne.id);
  const lines = t.trade_order_lines.filter((l) => l.order_id === order.id);
  const deal = t.deals.find((d) => d.company_id === varenne.id);
  return {
    companies: [varenne], contacts: [marc],
    company_contacts: [t.company_contacts.find((r) => r.contact_id === marc.id)],
    deals: [deal], deal_contacts: [t.deal_contacts.find((r) => r.deal_id === deal.id)],
    trade_products: [], trade_orders: [order], trade_order_lines: lines,
    trade_invoices: [t.trade_invoices.find((i) => i.order_id === order.id)],
    trade_stock_movements: [t.trade_stock_movements.find((m) => m.kind === 'shipment' && lines.some((l) => l.id === m.order_line_id))],
    trade_expenses: [t.trade_expenses[0]],
  };
}

// Adds every FK target of the picked rows until nothing changes; kept in full-run order.
function closeOverForeignKeys(full, picks) {
  const chosen = new Map(TABLES.map((t) => [t.name, new Set(picks[t.name].map((r) => r.id))]));
  let grew = true;
  while (grew) {
    grew = false;
    for (const t of TABLES) {
      for (const row of full.tables[t.name]) {
        if (!chosen.get(t.name).has(row.id)) continue;
        for (const c of t.columns) {
          if (c.fk && row[c.name] !== null && !chosen.get(c.fk).has(row[c.name])) {
            chosen.get(c.fk).add(row[c.name]);
            grew = true;
          }
        }
      }
    }
  }
  return Object.fromEntries(TABLES.map((t) => [t.name, full.tables[t.name].filter((r) => chosen.get(t.name).has(r.id))]));
}

function spikePages(full) {
  const byKey = new Map(full.pages.map((p) => [p.seed_key, p]));
  const keep = new Set();
  const withParents = (key) => {
    for (let k = key; k && !keep.has(k); k = byKey.get(k).parent_seed_key) keep.add(k);
  };
  [HOME, SPIKE_NOTE, SPIKE_DECISION, SHARED].forEach(withParents);
  return full.pages.filter((p) => keep.has(p.seed_key));
}

export function spikeDataset(full) {
  const picks = seedPicks(full);
  const marcId = picks.contacts[0].id;
  const interaction = full.interactions.find((d) => d.contact_id === marcId && d.kind === 'call' && d.deal_id === null);
  picks.contacts.push(...full.tables.contacts.filter((c) => c.id === interaction.owner_contact_id));
  return {
    ...full,
    spike: true,
    tables: closeOverForeignKeys(full, picks),
    interactions: [interaction],
    library: full.library.filter((i) => i.title === HUB_BOOK),
    pages: spikePages(full),
  };
}

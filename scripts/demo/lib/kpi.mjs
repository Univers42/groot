// Every report view recomputed from the generated rows, and the reconcile checks: one SQL
// query per view, with the exact text psql must print. Money is integer cents, formatted the
// way PostgreSQL prints numeric(·,2); percentages round half away from zero, as round() does.
import { createHash } from 'node:crypto';
import { centsText, daysBetween, quarterOf, monthOf } from './prng.mjs';

// Caveat: PostgreSQL divides numeric at >= 16 significant digits before round(); a quotient within
// 1e-16 of a .x5 boundary could round the other way there. The reconcile check then fails loudly.
export function pct1(part, whole) {
  if (whole === 0) return '0.0';
  const scaled = 1000 * part;
  let tenths = Math.floor(scaled / whole);
  if (2 * (scaled - tenths * whole) >= whole) tenths += 1;
  return `${Math.floor(tenths / 10)}.${tenths % 10}`;
}

function md5(textValue) {
  return createHash('md5').update(textValue, 'utf8').digest('hex'); // NOSONAR: matches PostgreSQL md5() for synthetic report reconciliation, never authentication.
}

// Code-point order per key, as ORDER BY … COLLATE "C" does on UTF-8 text.
function byKeys(a, b) {
  for (let i = 0; i < a.keys.length; i += 1) {
    if (a.keys[i] < b.keys[i]) return -1;
    if (a.keys[i] > b.keys[i]) return 1;
  }
  return 0;
}

function groupSum(rows, keyOf, fields) {
  const groups = new Map();
  for (const row of rows) {
    const keys = keyOf(row);
    const id = keys.join('\u0000');
    if (!groups.has(id)) groups.set(id, { keys, count: 0, ...Object.fromEntries(fields.map(([f]) => [f, 0])) });
    const g = groups.get(id);
    g.count += 1;
    for (const [f, valueOf] of fields) g[f] += valueOf(row);
  }
  return [...groups.values()].sort(byKeys);
}

export function computeKpis(tables, anchor) {
  const orderById = new Map(tables.trade_orders.map((o) => [o.id, o]));
  const productById = new Map(tables.trade_products.map((p) => [p.id, p]));
  const companyById = new Map(tables.companies.map((c) => [c.id, c]));
  const invoiced = new Set(tables.trade_invoices.map((i) => i.order_id));
  const invoicedLines = tables.trade_order_lines.filter((l) => invoiced.has(l.order_id));
  const cost = (l) => l.quantity * l.unit_cost_eur;

  const revenue = groupSum(tables.trade_invoices, (i) => [monthOf(i.issued_on)],
    [['net', (i) => i.net_eur], ['vat', (i) => i.vat_eur], ['total', (i) => i.total_eur]]);
  const margin = groupSum(invoicedLines, (l) => [productById.get(l.product_id).category],
    [['revenue', (l) => l.line_net_eur], ['cost', cost]]);
  const recent = tables.trade_invoices.filter((i) => daysBetween(i.issued_on, anchor) < 365);
  const clients = groupSum(recent, (i) => [companyById.get(i.company_id).name], [['revenue', (i) => i.net_eur]])
    .sort((a, b) => b.revenue - a.revenue || byKeys(a, b));
  clients.forEach((c, n) => { c.rank = n > 0 && clients[n - 1].revenue === c.revenue ? clients[n - 1].rank : n + 1; });
  const late = tables.trade_invoices.filter((i) => i.paid_on === null && i.due_on < anchor);
  const onHand = new Map();
  for (const m of tables.trade_stock_movements) onHand.set(m.product_id, (onHand.get(m.product_id) || 0) + m.quantity);
  const below = tables.trade_products.filter((p) => p.stocked && (onHand.get(p.id) || 0) < p.reorder_point)
    .map((p) => p.sku).sort();
  const pipeline = groupSum(tables.deals, (d) => [d.stage],
    [['amount', (d) => d.amount_eur], ['weighted', (d) => (d.amount_eur * d.probability_pct) / 100]]);
  const liveLines = tables.trade_order_lines.filter((l) => orderById.get(l.order_id).status !== 'cancelled');
  const channels = groupSum(liveLines, (l) => [orderById.get(l.order_id).department, orderById.get(l.order_id).channel],
    [['net', (l) => l.line_net_eur]]);
  for (const g of channels) {
    g.orders = new Set(liveLines.filter((l) => {
      const o = orderById.get(l.order_id);
      return o.department === g.keys[0] && o.channel === g.keys[1];
    }).map((l) => l.order_id)).size;
  }
  const expenses = groupSum(tables.trade_expenses, (e) => [monthOf(e.spent_on), e.category], [['amount', (e) => e.amount_eur]]);
  return { revenue, margin, clients, late, below, pipeline, channels, expenses,
    clv: lifetimeValue(tables, orderById, companyById, invoicedLines, cost),
    dependency: supplierDependency(tables, productById, companyById) };
}

function lifetimeValue(tables, orderById, companyById, invoicedLines, cost) {
  const live = tables.trade_orders.filter((o) => o.status !== 'cancelled');
  const rows = groupSum(live, (o) => [companyById.get(o.company_id).name], []);
  const net = new Map();
  for (const i of tables.trade_invoices) net.set(i.company_id, (net.get(i.company_id) || 0) + i.net_eur);
  const earned = new Map();
  for (const l of invoicedLines) {
    const company = orderById.get(l.order_id).company_id;
    earned.set(company, (earned.get(company) || 0) + l.line_net_eur - cost(l));
  }
  const idByName = new Map(tables.companies.map((c) => [c.name, c.id]));
  return rows.map((r) => ({ ...r, net: net.get(idByName.get(r.keys[0])) || 0, margin: earned.get(idByName.get(r.keys[0])) || 0 }));
}

function supplierDependency(tables, productById, companyById) {
  const receipts = tables.trade_stock_movements.filter((m) => m.kind === 'receipt');
  const rows = groupSum(receipts, (m) => [quarterOf(m.moved_on), productById.get(m.product_id).category,
    companyById.get(m.supplier_id).name], [['purchase', (m) => m.quantity * m.unit_cost_eur]]);
  const totals = new Map();
  for (const r of rows) totals.set(`${r.keys[0]}/${r.keys[1]}`, (totals.get(`${r.keys[0]}/${r.keys[1]}`) || 0) + r.purchase);
  return rows.map((r) => ({ ...r, share: pct1(r.purchase, totals.get(`${r.keys[0]}/${r.keys[1]}`)) }));
}

const C = 'COLLATE "C"';

export function reconcileChecks(k) {
  const join = (rows, fmt) => rows.map(fmt).join(',');
  return [
    { name: 'revenue_by_month', sql: `SELECT string_agg(month || '=' || invoices || '/' || net_eur || '/' || total_eur, ',' ORDER BY month ${C}) FROM report_revenue_by_month`,
      expected: join(k.revenue, (r) => `${r.keys[0]}=${r.count}/${centsText(r.net)}/${centsText(r.total)}`) },
    { name: 'margin_by_category', sql: `SELECT string_agg(category || '=' || revenue_eur || '/' || cost_eur || '/' || margin_pct, ',' ORDER BY category ${C}) FROM report_margin_by_category`,
      expected: join(k.margin, (r) => `${r.keys[0]}=${centsText(r.revenue)}/${centsText(r.cost)}/${pct1(r.revenue - r.cost, r.revenue)}`) },
    { name: 'top_clients', sql: `SELECT string_agg(rank || '=' || name || '/' || revenue_eur, ',' ORDER BY rank, name ${C}) FROM report_top_clients WHERE rank <= 5`,
      expected: join(k.clients.filter((c) => c.rank <= 5), (c) => `${c.rank}=${c.keys[0]}/${centsText(c.revenue)}`) },
    { name: 'late_invoices', sql: 'SELECT count(*) || \'/\' || coalesce(sum(total_eur), 0.00) FROM report_late_invoices',
      expected: `${k.late.length}/${centsText(k.late.reduce((s, i) => s + i.total_eur, 0))}` },
    { name: 'stock_below_reorder', sql: `SELECT coalesce(string_agg(sku, ',' ORDER BY sku ${C}), '') FROM report_stock_below_reorder`,
      expected: k.below.join(',') },
    { name: 'pipeline_by_stage', sql: `SELECT string_agg(stage || '=' || deals || '/' || amount_eur || '/' || weighted_eur, ',' ORDER BY stage ${C}) FROM report_pipeline_by_stage`,
      expected: join(k.pipeline, (r) => `${r.keys[0]}=${r.count}/${centsText(r.amount)}/${centsText(r.weighted)}`) },
    { name: 'orders_by_department_channel', sql: `SELECT string_agg(department || '/' || channel || '=' || orders || '/' || net_eur, ',' ORDER BY department ${C}, channel ${C}) FROM report_orders_by_department_channel`,
      expected: join(k.channels, (r) => `${r.keys[0]}/${r.keys[1]}=${r.orders}/${centsText(r.net)}`) },
    { name: 'expenses_by_month_category', sql: `SELECT md5(string_agg(month || '/' || category || '=' || expenses || '/' || amount_eur, ',' ORDER BY month ${C}, category ${C})) FROM report_expenses_by_month_category`,
      expected: md5(join(k.expenses, (r) => `${r.keys[0]}/${r.keys[1]}=${r.count}/${centsText(r.amount)}`)) },
    { name: 'client_lifetime_value', sql: `SELECT md5(string_agg(name || '=' || orders || '/' || invoiced_net_eur || '/' || margin_eur, ',' ORDER BY name ${C})) FROM report_client_lifetime_value`,
      expected: md5(join(k.clv, (r) => `${r.keys[0]}=${r.count}/${centsText(r.net)}/${centsText(r.margin)}`)) },
    { name: 'supplier_dependency', sql: `SELECT md5(string_agg(quarter || '/' || category || '/' || supplier || '=' || purchase_eur || '/' || share_pct, ',' ORDER BY quarter ${C}, category ${C}, supplier ${C})) FROM report_supplier_dependency`,
      expected: md5(join(k.dependency, (r) => `${r.keys.join('/')}=${centsText(r.purchase)}/${r.share}`)) },
    { name: 'invoices_equal_their_lines', sql: 'SELECT count(*) FROM trade_invoices i WHERE i.net_eur <> (SELECT sum(l.line_net_eur) FROM trade_order_lines l WHERE l.order_id = i.order_id)',
      expected: '0' },
    { name: 'stock_never_negative_at_anchor', sql: 'SELECT count(*) FROM report_stock_levels WHERE on_hand < 0', expected: '0' },
  ];
}

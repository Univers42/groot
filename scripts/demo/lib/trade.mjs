// 18 months of Arlet trading to the anchor: products, orders, order lines and invoices.
// Money is integer cents; a line's net rounds half-up exactly like PostgreSQL's round(numeric, 2).
import { idFor } from './uuid.mjs';
import { forkRng, addDays, addMonths, isWeekday, daysBetween } from './prng.mjs';
import { CATEGORIES, catalogueEntries } from './catalogue.mjs';

const SEASON = [0.8, 0.9, 1.1, 1.2, 1.25, 1.15, 0.85, 0.5, 1.15, 1.1, 1.05, 0.9];
const ORDERS_PER_DAY = 4.5;
const EQUIPMENT = ['cooking', 'refrigeration', 'dishwashing', 'preparation', 'ventilation', 'stainless_furniture'];
const SALES_MIX = { smallwares: 30, consumables: 22, refrigeration: 8, preparation: 7, cooking: 6,
  dishwashing: 4, stainless_furniture: 6, ventilation: 2, spare_parts: 6 };

export function lineNetCents(quantity, priceCents, discountPct) {
  return Math.floor((quantity * priceCents * (100 - discountPct) + 50) / 100);
}

export function vatCents(netCents) {
  return Math.floor((netCents * 20 + 50) / 100);
}

function buildProducts(rng, idx) {
  const counters = {};
  return catalogueEntries().map((entry) => {
    const spec = CATEGORIES[entry.category];
    counters[entry.category] = (counters[entry.category] || 0) + 1;
    const raw = Math.round((entry.costCents * (100 + spec.markup)) / 10000) * 100 - 10;
    return {
      id: idFor('trade_products', `${entry.category}:${entry.name}`),
      sku: `ARL-${entry.category.slice(0, 3).toUpperCase()}-${String(counters[entry.category]).padStart(3, '0')}`,
      name: entry.name, category: entry.category,
      supplier_id: idx.companyByName.get(spec.supplier).id,
      second_supplier_id: spec.second ? idx.companyByName.get(spec.second).id : null,
      unit_cost_eur: entry.costCents, unit_price_eur: Math.max(raw, entry.costCents + 90),
      stocked: spec.stocked === true || (spec.stocked === 'core' && entry.core), reorder_point: 0, reorder_qty: 1, lead_time_days: spec.lead + rng.int(-2, 3),
    };
  });
}

function clientWeight(company) {
  if (company.name === 'Hôtel Varenne') return 9;
  return 0.6 + company.credit_limit_eur / 3000000;
}

function pickContact(rng, idx, company, preferredRoles) {
  const people = idx.contactsByCompany.get(company.id);
  const preferred = people.filter((p) => preferredRoles.includes(idx.primaryRole.get(p.id)));
  return preferred.length > 0 && rng.chance(0.75) ? rng.pick(preferred) : rng.pick(people);
}

function pickChannel(rng, day, portalOn) {
  const portal = day >= portalOn ? 22 : 4;
  const options = [['field_sales', 34], ['phone', 26], ['email', 20], ['web_portal', portal]];
  return rng.weighted(options, ([, w]) => w)[0];
}

function lineFor(rng, ctx, order, product, discount) {
  const [min, max] = CATEGORIES[product.category].qty;
  const boost = order.company_id === ctx.idx.varenne.id && max > 2 ? 2 : 1;
  const quantity = Math.min(max * boost, rng.int(min, max) * boost);
  return {
    order_id: order.id, product_id: product.id, quantity, unit_price_eur: product.unit_price_eur,
    unit_cost_eur: product.unit_cost_eur, discount_pct: discount,
    line_net_eur: lineNetCents(quantity, product.unit_price_eur, discount),
  };
}

function regularLines(rng, ctx, order) {
  const service = order.department === 'service';
  const count = service ? rng.int(1, 3) : rng.int(1, 5);
  const discount = order.company_id === ctx.idx.varenne.id ? 12 : rng.pick([0, 0, 0, 5, 5, 10]);
  const chosen = new Set();
  const lines = [];
  for (let i = 0; i < count; i += 1) {
    const category = service
      ? (rng.chance(0.7) ? 'spare_parts' : 'consumables')
      : rng.weighted(Object.keys(SALES_MIX), (c) => SALES_MIX[c]);
    const product = rng.pick(ctx.byCategory[category]);
    if (chosen.has(product.id)) continue;
    chosen.add(product.id);
    lines.push(lineFor(rng, ctx, order, product, discount));
  }
  return lines;
}

// A won deal turns into one equipment order worth roughly the deal amount.
// Caveat: lines are added until they reach 85% of the amount, capped at 8 products, so the order
// can overshoot by one line or fall short; won-deal amounts never equal invoiced revenue exactly.
function dealLines(rng, ctx, order, deal) {
  const pool = EQUIPMENT.flatMap((c) => ctx.byCategory[c]);
  const discount = rng.int(8, 15);
  const lines = [];
  let total = 0;
  for (const product of rng.sample(pool, 8)) {
    if (total >= deal.amount_eur * 0.85) break;
    const line = lineFor(rng, ctx, order, product, discount);
    lines.push(line);
    total += line.line_net_eur;
  }
  return lines;
}

function newOrder(rng, ctx, day, company, department) {
  const idx = ctx.idx;
  const contact = pickContact(rng, idx, company, department === 'service'
    ? ['technical_contact', 'head_chef'] : ['buyer', 'general_manager', 'head_chef']);
  const salesperson = department === 'service' ? rng.pick(idx.staff.service) : idx.accountManager.get(company.id);
  return {
    id: null, order_no: null, company_id: company.id, contact_id: contact.id, salesperson_id: salesperson.id,
    deal_id: null, department, channel: pickChannel(rng, day, ctx.story.portalOn),
    status: 'shipped', ordered_on: day, shipped_on: null,
  };
}

function draftOrders(rng, ctx) {
  const drafts = [];
  for (let day = ctx.start; day < ctx.anchor; day = addDays(day, 1)) {
    if (!isWeekday(day)) continue;
    const elapsed = daysBetween(ctx.start, day) / daysBetween(ctx.start, ctx.anchor);
    const mean = ORDERS_PER_DAY * SEASON[Number(day.slice(5, 7)) - 1] * (0.9 + 0.2 * elapsed);
    for (let n = rng.poisson(mean); n > 0; n -= 1) {
      const company = rng.weighted(ctx.idx.clients, clientWeight);
      const order = newOrder(rng, ctx, day, company, rng.chance(0.35) ? 'service' : 'sales');
      drafts.push({ order, lines: regularLines(rng, ctx, order) });
    }
  }
  for (const deal of ctx.idx.deals) {
    if (deal.stage !== 'won') continue;
    const day = addDays(deal.closed_on, rng.int(3, 20));
    if (day >= ctx.anchor) continue;
    const order = newOrder(rng, ctx, day, ctx.idx.companyById.get(deal.company_id), 'sales');
    order.deal_id = deal.id;
    order.channel = 'field_sales';
    drafts.push({ order, lines: dealLines(rng, ctx, order, deal) });
  }
  return drafts.filter((d) => d.lines.length > 0);
}

function settle(rng, ctx, drafts) {
  drafts.sort((a, b) => (a.order.ordered_on < b.order.ordered_on ? -1 : a.order.ordered_on > b.order.ordered_on ? 1 : 0));
  const orders = [];
  const lines = [];
  const invoices = [];
  drafts.forEach(({ order, lines: draftLines }, n) => {
    const year = order.ordered_on.slice(0, 4);
    order.order_no = `CMD-${year}-${String(n + 1).padStart(5, '0')}`;
    order.id = idFor('trade_orders', order.order_no);
    const shipped = addDays(order.ordered_on, rng.int(1, 4));
    if (!order.deal_id && rng.chance(0.03)) order.status = 'cancelled';
    else if (shipped > ctx.anchor) order.status = 'open';
    else order.shipped_on = shipped;
    orders.push(order);
    draftLines.forEach((line, i) => {
      line.order_id = order.id;
      line.line_no = i + 1;
      line.id = idFor('trade_order_lines', `${order.order_no}:${i + 1}`);
      lines.push(line);
    });
    if (order.status === 'shipped') invoices.push(invoiceFor(rng, ctx, order, draftLines));
  });
  return { orders, lines, invoices };
}

function invoiceFor(rng, ctx, order, orderLines) {
  const company = ctx.idx.companyById.get(order.company_id);
  const net = orderLines.reduce((sum, l) => sum + l.line_net_eur, 0);
  const vat = vatCents(net);
  const due = addDays(order.shipped_on, company.payment_terms_days);
  const slowPayer = company.segment === 'collective_catering';
  let paid = addDays(due, rng.int(-12, slowPayer ? 35 : 12));
  if (paid < order.shipped_on) paid = order.shipped_on;
  if (rng.chance(0.02) || paid > ctx.anchor) paid = null;
  return {
    id: idFor('trade_invoices', order.order_no), invoice_no: order.order_no.replace('CMD', 'FAC'),
    order_id: order.id, company_id: order.company_id, issued_on: order.shipped_on, due_on: due,
    paid_on: paid, net_eur: net, vat_eur: vat, total_eur: net + vat,
  };
}

export function buildTrade({ seed, anchor }, idx, story) {
  const rng = forkRng(seed, 'trade');
  const products = buildProducts(rng, idx);
  const byCategory = {};
  for (const p of products) (byCategory[p.category] ||= []).push(p);
  const ctx = { idx, anchor, start: addMonths(anchor, -18), byCategory, story };
  const { orders, lines, invoices } = settle(rng, ctx, draftOrders(rng, ctx));
  return { products, orders, lines, invoices, start: ctx.start };
}

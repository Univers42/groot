// Day-by-day stock simulation for stocked products. It writes the movements and sets each
// product's current reorder policy, so two stories are in the rows and not only in prose:
//   - before story.reorderRuleOn the reorder point was a flat rule that ignored lead time,
//     so stock-outs forced expedited receipts; after it, ROP = demand × lead time × 1.5;
//   - before story.switchOn refrigeration came from Frigeco alone, with late deliveries;
//     after it, receipts are split with Nordval (the "Supplier switch" decision).
// Receipts that would arrive after the anchor are in transit and not written, which is what
// leaves a few products below their reorder point on the dashboard.
import { idFor } from './uuid.mjs';
import { forkRng, addDays, daysBetween } from './prng.mjs';

const OLD_RULE = { refrigeration: 1, preparation: 1, smallwares: 6, spare_parts: 3 };

function demandPerDay(products, lines, orderById, days) {
  const demand = new Map(products.map((p) => [p.id, 0]));
  for (const line of lines) {
    if (orderById.get(line.order_id).status === 'shipped') demand.set(line.product_id, demand.get(line.product_id) + line.quantity);
  }
  for (const [id, qty] of demand) demand.set(id, qty / days);
  return demand;
}

function setPolicy(products, demand) {
  for (const p of products) {
    const d = demand.get(p.id);
    p.reorder_point = p.stocked ? Math.ceil(d * p.lead_time_days * 1.5) + 1 : 0;
    p.reorder_qty = Math.max(p.stocked ? Math.ceil(d * 45) : 1, 1);
  }
}

function shipmentsByDay(lines, orderById, stockedIds) {
  const byDay = new Map();
  for (const line of lines) {
    const order = orderById.get(line.order_id);
    if (order.status !== 'shipped' || !stockedIds.has(line.product_id)) continue;
    if (!byDay.has(order.shipped_on)) byDay.set(order.shipped_on, []);
    byDay.get(order.shipped_on).push(line);
  }
  return byDay;
}

function supplierFor(rng, ctx, product, day) {
  if (!product.second_supplier_id || day < ctx.story.switchOn) return product.supplier_id;
  return rng.chance(0.45) ? product.second_supplier_id : product.supplier_id;
}

function leadFor(rng, ctx, product, supplierId, day) {
  if (supplierId === product.second_supplier_id) return rng.int(8, 12);
  if (product.second_supplier_id && day < ctx.story.switchOn) return product.lead_time_days + rng.int(8, 22);
  return product.lead_time_days + rng.int(-2, 3);
}

export function simulateStock({ seed, anchor }, trade, story) {
  const rng = forkRng(seed, 'stock');
  const orderById = new Map(trade.orders.map((o) => [o.id, o]));
  const days = daysBetween(trade.start, anchor);
  const demand = demandPerDay(trade.products, trade.lines, orderById, days);
  setPolicy(trade.products, demand);
  const stocked = trade.products.filter((p) => p.stocked);
  const byDay = shipmentsByDay(trade.lines, orderById, new Set(stocked.map((p) => p.id)));
  const productById = new Map(trade.products.map((p) => [p.id, p]));
  const ctx = { story, anchor };
  const moves = [];
  const level = new Map();
  const onOrder = new Map();
  const arrivals = new Map();
  const move = (product, day, kind, quantity, extra = {}) => {
    moves.push({
      id: idFor('trade_stock_movements', `${product.sku}:${moves.length}`), product_id: product.id, moved_on: day,
      kind, quantity, order_line_id: extra.line ?? null, supplier_id: extra.supplier ?? null,
      unit_cost_eur: extra.supplier ? extra.cost : null, expedited: Boolean(extra.expedited),
    });
    level.set(product.id, (level.get(product.id) || 0) + quantity);
  };
  const receive = (product, day, quantity, expedited) => {
    const supplier = supplierFor(rng, ctx, product, day);
    const cost = supplier === product.second_supplier_id ? Math.round(product.unit_cost_eur * 1.03) : product.unit_cost_eur;
    move(product, day, 'receipt', quantity, { supplier, cost, expedited });
  };
  for (const p of stocked) move(p, trade.start, 'opening', Math.max(p.reorder_qty + p.reorder_point, 2));
  const returns = new Map();
  for (let day = trade.start; day <= anchor; day = addDays(day, 1)) {
    for (const [productId, qty] of arrivals.get(day) || []) {
      receive(productById.get(productId), day, qty, false);
      onOrder.set(productId, onOrder.get(productId) - qty);
    }
    for (const line of byDay.get(day) || []) {
      const product = productById.get(line.product_id);
      const short = line.quantity - level.get(product.id);
      if (short > 0) receive(product, day, short + product.reorder_qty, true);
      move(product, day, 'shipment', -line.quantity, { line: line.id });
      if (rng.chance(0.03)) {
        const back = addDays(day, rng.int(5, 20));
        if (!returns.has(back)) returns.set(back, []);
        returns.get(back).push(line);
      }
    }
    for (const line of returns.get(day) || []) {
      move(productById.get(line.product_id), day, 'return', rng.int(1, line.quantity), { line: line.id });
    }
    if (rng.chance(0.5)) {
      const p = rng.pick(stocked);
      const delta = rng.chance(0.5) ? rng.int(1, 3) : -rng.int(1, 3);
      if (level.get(p.id) + delta >= 0) move(p, day, 'adjustment', delta);
    }
    for (const p of stocked) {
      const rop = day < story.reorderRuleOn ? OLD_RULE[p.category] : p.reorder_point;
      if (level.get(p.id) + (onOrder.get(p.id) || 0) > rop) continue;
      const supplier = supplierFor(rng, ctx, p, day);
      const arrive = addDays(day, leadFor(rng, ctx, p, supplier, day));
      onOrder.set(p.id, (onOrder.get(p.id) || 0) + p.reorder_qty);
      if (!arrivals.has(arrive)) arrivals.set(arrive, []);
      arrivals.get(arrive).push([p.id, p.reorder_qty]);
    }
  }
  return moves;
}

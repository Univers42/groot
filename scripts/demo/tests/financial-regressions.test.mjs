import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildCrm } from '../lib/crm.mjs';
import { buildExpenses } from '../lib/expenses.mjs';
import { computeKpis, pct1, reconcileChecks } from '../lib/kpi.mjs';
import { simulateStock } from '../lib/stock.mjs';
import { ARGS, fixture } from './helpers.mjs';

test('monthly expenses stay in their assigned month when the start is month-end', () => {
  const args = { ...ARGS, anchor: '2027-08-01' };
  const rows = buildExpenses(args, buildCrm(args).idx, '2026-01-31');
  const rent = rows.filter((r) => r.category === 'rent');
  assert.equal(rent.length, 18);
  assert.equal(rent[0].spent_on, '2026-01-05');
  assert.equal(rent.at(-1).spent_on, '2027-06-05');
  const scheduled = rows.filter((r) => !r.description.startsWith('Executive certificate'));
  const months = new Map();
  for (const row of scheduled) {
    assert.ok(Number(row.spent_on.slice(8)) <= 28);
    const month = row.spent_on.slice(0, 7);
    months.set(month, (months.get(month) || 0) + 1);
  }
  assert.equal(months.size, 18);
  assert.ok([...months.values()].every((n) => n === 31));
});

test('percentages round negative halves away from zero and format the sign once', () => {
  for (const [part, whole, expected] of [[1, 16, '6.3'], [-1, 16, '-6.3'],
    [-1, 3, '-33.3'], [-1, 2000, '-0.1'], [0, 100, '0.0'], [1, 0, '0.0']]) {
    assert.equal(pct1(part, whole), expected);
  }
});

test('weighted pipeline rounds after summing fractional cents', () => {
  const tables = { ...fixture().dataset.tables, deals: [
    { stage: 'proposal', amount_eur: 1, probability_pct: 25 },
    { stage: 'proposal', amount_eur: 1, probability_pct: 25 },
  ] };
  const kpis = computeKpis(tables, ARGS.anchor);
  assert.equal(reconcileChecks(kpis).find((c) => c.name === 'pipeline_by_stage').expected,
    'proposal=2/0.02/0.01');
});

test('a scheduled receipt keeps the supplier chosen before the supplier switch', () => {
  const moves = simulateStock({ seed: 0, anchor: '2026-03-01' }, {
    start: '2026-01-01',
    products: [{ id: 'product', sku: 'SKU', category: 'refrigeration', stocked: true,
      supplier_id: 'original', second_supplier_id: 'new', lead_time_days: 10, unit_cost_eur: 100 }],
    orders: [{ id: 'order', status: 'shipped', shipped_on: '2026-01-01' }],
    lines: [{ id: 'line', order_id: 'order', product_id: 'product', quantity: 60 }],
  }, { switchOn: '2026-01-02', reorderRuleOn: '2026-01-01' });
  const receipt = moves.find((m) => m.kind === 'receipt' && !m.expedited);
  assert.ok(receipt);
  assert.ok(receipt.moved_on > '2026-01-02');
  assert.equal(receipt.supplier_id, 'original');
  assert.equal(receipt.unit_cost_eur, 100);
});

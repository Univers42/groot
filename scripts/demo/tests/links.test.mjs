import { test } from 'node:test';
import assert from 'node:assert/strict';
import { linkGraph } from '../lib/graph.mjs';
import { pageRelations } from '../lib/page-format.mjs';
import { fixture } from './helpers.mjs';

test('at least 3 links per record on average, and no orphan', () => {
  const graph = linkGraph(fixture().dataset);
  assert.ok(graph.average >= 3, `average ${graph.average}`);
  assert.deepEqual(graph.orphans, []);
});

test('a planted orphan is reported', () => {
  const copy = structuredClone(fixture().dataset);
  copy.library.push({ _id: 'aaaaaaaa-0000-5000-8000-000000000000', kind: 'file', title: 'stray', tags: [] });
  assert.deepEqual(linkGraph(copy).orphans, ['library:aaaaaaaa-0000-5000-8000-000000000000']);
});

test('the three hubs are the largest of their kind', () => {
  const { dataset } = fixture();
  const stats = JSON.parse(fixture().files['stats.json']);
  assert.equal(stats.kpi.top_client.name, 'Hôtel Varenne');
  const byRelations = [...dataset.pages].sort((a, b) => pageRelations(b).length - pageRelations(a).length);
  assert.equal(byRelations[0].title, 'Supplier switch');
  const cited = [...dataset.library].sort((a, b) => b.cited_in.length - a.cited_in.length);
  assert.equal(cited[0].title, 'The Two-Supplier Rule');
});

test('volumes match the plan', () => {
  const { counts } = JSON.parse(fixture().files['stats.json']);
  const exact = { companies: 60, contacts: 220, deals: 80, trade_products: 120 };
  for (const [name, n] of Object.entries(exact)) assert.equal(counts[name], n, name);
  const near = {
    company_contacts: 300, deal_contacts: 200, trade_orders: 1800, trade_order_lines: 5000,
    trade_invoices: 1800, trade_stock_movements: 3000, trade_expenses: 600,
    interactions: 700, library: 250, pages: 145,
  };
  for (const [name, n] of Object.entries(near)) {
    assert.ok(Math.abs(counts[name] - n) <= n * 0.15, `${name}=${counts[name]} not near ${n}`);
  }
});

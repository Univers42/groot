// stats.json: counts, the link measure, and the KPI totals with their reconcile queries, so a
// verifier compares the loaded mount against these numbers instead of trusting the loader.
import { TABLES } from './tables.mjs';
import { linkGraph, integrityErrors } from './graph.mjs';
import { computeKpis, reconcileChecks } from './kpi.mjs';
import { centsText } from './prng.mjs';

export function buildStats(dataset) {
  const { args } = dataset;
  const graph = linkGraph(dataset);
  const k = computeKpis(dataset.tables, args.anchor);
  const counts = Object.fromEntries(TABLES.map((t) => [t.name, dataset.tables[t.name].length]));
  Object.assign(counts, {
    interactions: dataset.interactions.length, library: dataset.library.length, pages: dataset.pages.length,
  });
  const top = k.clients[0];
  return {
    mode: dataset.spike ? 'spike' : 'full',
    args,
    databases: { crm: `demo_${args.uid8}_crm`, activity: `demo_${args.uid8}_activity` },
    counts,
    links: {
      records: graph.records, links: graph.links, per_record: Number(graph.average.toFixed(2)), orphans: graph.orphans,
      // Spike only: references to records the full run adds. Always 0 in a full run.
      deferred_references: dataset.spike ? integrityErrors(dataset).length : 0,
    },
    kpi: {
      revenue_by_month: k.revenue.map((r) => ({ month: r.keys[0], invoices: r.count, net_eur: centsText(r.net), total_eur: centsText(r.total) })),
      invoiced_net_eur: centsText(k.revenue.reduce((s, r) => s + r.net, 0)),
      top_client: top ? { name: top.keys[0], revenue_12m_eur: centsText(top.revenue) } : null,
      late_invoices: { count: k.late.length, total_eur: centsText(k.late.reduce((s, i) => s + i.total_eur, 0)) },
      stock_below_reorder: k.below,
      pipeline_by_stage: k.pipeline.map((r) => ({ stage: r.keys[0], deals: r.count, amount_eur: centsText(r.amount), weighted_eur: centsText(r.weighted) })),
      expenses_eur: centsText(k.expenses.reduce((s, r) => s + r.amount, 0)),
      story: dataset.facts,
    },
    reconcile: reconcileChecks(k),
  };
}

// The dates the story turns on, as offsets back from the anchor, and the numbers the pages
// quote, computed from the generated rows so a page cannot claim what the data does not show.
import { addDays, quarterOf, daysBetween } from './prng.mjs';
import { pct1 } from './kpi.mjs';

export function storyDates(anchor) {
  return {
    portalOn: addDays(anchor, -330),
    switchOn: addDays(anchor, -210),
    reorderRuleOn: addDays(anchor, -150),
  };
}

function previousQuarter(anchor) {
  const [year, q] = quarterOf(anchor).split('-Q').map(Number);
  return q === 1 ? `${year - 1}-Q4` : `${year}-Q${q - 1}`;
}

export function storyFacts({ anchor, story, trade, moves, tables }) {
  const productById = new Map(trade.products.map((p) => [p.id, p]));
  const isRefrigeration = (m) => productById.get(m.product_id).category === 'refrigeration';
  const expedited = moves.filter((m) => m.expedited);
  const receipts = moves.filter((m) => m.kind === 'receipt' && isRefrigeration(m));
  const nordval = tables.companies.find((c) => c.name === 'Nordval Froid').id;
  const frigeco = tables.companies.find((c) => c.name === 'Frigeco Industrie').id;
  const value = (list) => list.reduce((sum, m) => sum + m.quantity * m.unit_cost_eur, 0);
  const sinceSwitch = receipts.filter((m) => m.moved_on >= story.switchOn);
  const quarter = previousQuarter(anchor);
  const inQuarter = receipts.filter((m) => quarterOf(m.moved_on) === quarter);
  const frigecoCents = value(inQuarter.filter((m) => m.supplier_id === frigeco));
  const nordvalCents = value(inQuarter.filter((m) => m.supplier_id === nordval));
  return {
    expeditedBefore: expedited.filter((m) => m.moved_on < story.reorderRuleOn).length,
    expeditedAfter: expedited.filter((m) => m.moved_on >= story.reorderRuleOn).length,
    monthsBeforeRule: Math.round(daysBetween(trade.start, story.reorderRuleOn) / 30.4),
    monthsAfterRule: Math.round(daysBetween(story.reorderRuleOn, anchor) / 30.4),
    expeditedRefrigerationBefore: expedited.filter((m) => isRefrigeration(m) && m.moved_on < story.switchOn).length,
    expeditedRefrigerationAfter: expedited.filter((m) => isRefrigeration(m) && m.moved_on >= story.switchOn).length,
    nordvalSharePct: pct1(value(sinceSwitch.filter((m) => m.supplier_id === nordval)), value(sinceSwitch)),
    lateInvoices: tables.trade_invoices.filter((i) => i.paid_on === null && i.due_on < anchor).length,
    lastQuarter: {
      quarter, frigecoCents, nordvalCents,
      frigecoPct: pct1(frigecoCents, frigecoCents + nordvalCents), nordvalPct: pct1(nordvalCents, frigecoCents + nordvalCents),
    },
  };
}

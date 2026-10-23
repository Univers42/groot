// Every osionos page of the demo, keyed by a deterministic seed_key (the server mints page ids,
// the manifest maps seed keys to them). Builds the decision log and wires the reverse side of
// every relation and every note → library citation, so both directions are explicit.
import { forkRng, addDays, centsText } from './prng.mjs';
import { DECISIONS } from './decisions.mjs';
import { HUB_BOOK } from './library.mjs';
import { noteSkeletons, assignLibrary, academyPages, ACADEMY_ROOT } from './pages-academy.mjs';
import {
  text, date, select, tags, relation, uuidList, blocks, page, addReverse, pageRelations, uuidMentions,
} from './page-format.mjs';

const LOG = 'decision-log';
export const HOME = 'home';
export const SHARED = 'q4-supplier-review';
const PINNED = ['decision-supplier-switch', 'decision-stock-reorder-rule', 'decision-varenne-framework-contract', ACADEMY_ROOT];

function decisionDate(story, anchor, on) {
  return typeof on === 'number' ? addDays(anchor, -on) : story[on];
}

function factLine(decision, facts) {
  if (decision.slug === 'supplier-switch') {
    return `Since the switch, Nordval Froid supplied ${facts.nordvalSharePct}% of refrigeration receipts by value; expedited refrigeration receipts went from ${facts.expeditedRefrigerationBefore} before to ${facts.expeditedRefrigerationAfter} after.`;
  }
  if (decision.slug === 'stock-reorder-rule') {
    return `Expedited receipts: ${facts.expeditedBefore} in the ${facts.monthsBeforeRule} months before the rule, ${facts.expeditedAfter} in the ${facts.monthsAfterRule} months since.`;
  }
  return null;
}

function decisionPage(ctx, decision) {
  const seedKey = `decision-${decision.slug}`;
  const companies = decision.companies.map((name) => ctx.idx.companyByName.get(name));
  const people = [ctx.idx.people.ines, ...decision.people.map((key) => ctx.idx.people[key])];
  const books = decision.books.map((title) => ctx.library.find((item) => item.title === title));
  const deals = companies.some((c) => c === ctx.idx.varenne) && decision.slug === 'varenne-framework-contract'
    ? ctx.idx.deals.filter((d) => d.company_id === ctx.idx.varenne.id) : [];
  const decidedOn = ctx.decisionDates[decision.slug];
  const fact = factLine(decision, ctx.facts);
  const specs = [
    ['callout', `Decided ${decidedOn} · owner Inès Caradec · status ${decision.status}`],
    ['heading_2', 'Decision'], ['paragraph', decision.summary],
    ['heading_2', 'Context'], ['paragraph', decision.context],
    ['heading_2', 'Outcome'], ['paragraph', decision.outcome],
  ];
  if (fact) specs.push(['callout', fact]);
  if (decision.related.length > 0) {
    specs.push(['heading_2', 'Related decisions'], ...decision.related.map((r) => ['bulleted_list', `[[seed:decision-${r}]]`]));
  }
  return page({
    seedKey, workspace: 'operations', title: decision.title, icon: decision.icon, parent: LOG,
    properties: [
      select('status', 'Status', decision.status, ['Proposed', 'Trial', 'Adopted']),
      date('decided_on', 'Decided on', decidedOn),
      relation('informed_by', 'Informed by', []),
      relation('related_decisions', 'Related decisions', decision.related.map((r) => `decision-${r}`)),
      text('companies', 'Companies', companies.map((c) => c.name).join('; ')),
      uuidList('company_ids', 'Company refs', companies.map((c) => c.id)),
      uuidList('contact_ids', 'People refs', people.map((c) => c.id)),
      uuidList('library_ids', 'Library refs', books.map((b) => b._id)),
      uuidList('deal_ids', 'Deal refs', deals.map((d) => d.id)),
      tags(['decision', decision.status.toLowerCase()]),
    ],
    content: blocks(seedKey, specs),
  });
}

function homePage(ctx) {
  return page({
    seedKey: HOME, workspace: 'operations', title: 'Arlet — Operations', icon: '🏠',
    properties: [
      relation('pinned', 'Pinned', PINNED),
      uuidList('company_ids', 'Company refs', [ctx.idx.varenne.id]),
      uuidList('library_ids', 'Library refs', [ctx.library.find((i) => i.title === HUB_BOOK)._id]),
      tags(['home']),
    ],
    content: blocks(HOME, [
      ['heading_1', 'Arlet — Operations'],
      ['paragraph', `One record, read by sales, warehouse, finance and service. Data as of ${ctx.anchor}.`],
      ['heading_2', 'Hubs'],
      ...PINNED.map((key) => ['bulleted_list', `[[seed:${key}]]`]),
      ['heading_2', 'Reports'],
      ...['report_revenue_by_month', 'report_top_clients', 'report_late_invoices', 'report_stock_below_reorder',
        'report_pipeline_by_stage', 'report_supplier_dependency'].map((v) => ['bulleted_list', `CRM mount view ${v}`]),
      ['callout', `Top client over the last 12 months: Hôtel Varenne. Late invoices today: ${ctx.facts.lateInvoices}.`],
    ]),
  });
}

// Lives in the finance workspace that Jules can read. It carries no [[seed:]] link or relation:
// every other page is in the operations workspace, which he cannot open, so a link would dangle.
function sharedPage(ctx) {
  const f = ctx.facts.lastQuarter;
  const { jules, ines, thierry, camille } = ctx.idx.people;
  return page({
    seedKey: SHARED, workspace: 'finance', title: 'Q4 supplier review', icon: '📊', extra: { shared_with: 'jules' },
    properties: [
      { key: 'shared_with', label: 'Shared with', type: 'email', value: jules.email },
      select('share_role', 'Role', 'viewer', ['viewer', 'editor']),
      uuidList('company_ids', 'Company refs', [ctx.idx.companyByName.get('Frigeco Industrie').id, ctx.idx.companyByName.get('Nordval Froid').id]),
      uuidList('contact_ids', 'People refs', [ines.id, jules.id, thierry.id, camille.id]),
      tags(['finance', 'suppliers']),
    ],
    content: blocks(SHARED, [
      ['heading_1', 'Q4 supplier review'],
      ['paragraph', `Prepared by Inès Caradec for Jules Marchand. Refrigeration receipts in ${f.quarter}, by supplier:`],
      ['bulleted_list', `Frigeco Industrie: €${centsText(f.frigecoCents)} (${f.frigecoPct}%).`],
      ['bulleted_list', `Nordval Froid: €${centsText(f.nordvalCents)} (${f.nordvalPct}%).`],
      ['quote', 'One supplier is a dependency; two suppliers are a choice.'],
      ['to_do', 'Jules: confirm the Q4 purchase budget for refrigeration', false],
      ['to_do', 'Inès: renegotiate Frigeco delivery windows', true],
    ]),
  });
}

function wireReverse(pages, library) {
  const byKey = new Map(pages.map((p) => [p.seed_key, p]));
  for (const p of pages) {
    const informs = p.properties.find((x) => x.key === 'informs');
    for (const target of informs ? pageRelations({ properties: [informs] }) : []) addReverse(byKey.get(target), 'informed_by', 'Informed by', p.seed_key);
    const related = p.properties.find((x) => x.key === 'related_decisions');
    for (const target of related ? pageRelations({ properties: [related] }) : []) addReverse(byKey.get(target), 'related_decisions', 'Related decisions', p.seed_key);
  }
  for (const key of PINNED) addReverse(byKey.get(key), 'pinned_on', 'Pinned on', HOME);
  const itemById = new Map(library.map((i) => [i._id, i]));
  for (const p of pages) {
    for (const id of uuidMentions(p)) if (itemById.has(id)) itemById.get(id).cited_in.push(p.seed_key);
  }
}

export function buildPages({ seed, anchor }, idx, library, story, facts) {
  const rng = forkRng(seed, 'pages');
  const decisionDates = Object.fromEntries(DECISIONS.map((d) => [d.slug, decisionDate(story, anchor, d.on)]));
  const ctx = {
    rng, anchor, idx, library, facts, decisionDates,
    decisionBySlug: Object.fromEntries(DECISIONS.map((d) => [d.slug, d])),
  };
  const notes = noteSkeletons(ctx);
  assignLibrary(rng, notes, library);
  const log = page({
    seedKey: LOG, workspace: 'operations', title: 'Decision log', icon: '🗂️', properties: [tags(['decision'])],
    content: blocks(LOG, [['paragraph', 'Every operations decision: what, why, and the notes that informed it.'],
      ...DECISIONS.map((d) => ['bulleted_list', `[[seed:decision-${d.slug}]]`])]),
  });
  const pages = [
    homePage(ctx), ...academyPages(ctx, notes), log, ...DECISIONS.map((d) => decisionPage(ctx, d)), sharedPage(ctx),
  ];
  wireReverse(pages, library);
  return { pages };
}

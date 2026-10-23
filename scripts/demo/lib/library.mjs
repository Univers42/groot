// Inès's reading library (Mongo collection `library`): books, articles, papers and files, one
// shape per kind. `cited_in` (the pages citing an item) is filled by the page builder, so the
// reverse side of every note → library link is written explicitly.
//
// Caveat: titles, authors, outlets and ISBNs are invented. ISBNs carry a valid ISBN-13 check
// digit but are not registered; a real book could share one, and none is meant. DOIs use
// 10.5555, the prefix Crossref documents as a test prefix.
import { idFor } from './uuid.mjs';
import { forkRng, addDays, slug } from './prng.mjs';
import { FIRST_NAMES, LAST_NAMES } from './names.mjs';

export const HUB_BOOK = 'The Two-Supplier Rule';

const BOOKS = [
  [HUB_BOOK, 'Marguerite Ollier', 2021, ['sourcing', 'supplier-risk']],
  ['Stock Is a Decision', 'Pierre Vandamme', 2019, ['inventory', 'reorder-policy']],
  ['Margins Without Mysteries', 'Hannah Collister', 2020, ['finance', 'costing']],
  ['Field Service That Pays', 'Rémi Castagné', 2018, ['service', 'contracts']],
  ['The Quiet Warehouse', 'Ingrid Solberg', 2022, ['warehouse', 'lean']],
  ['Counting What Moves', 'Ada Brightwell', 2017, ['inventory', 'cycle-counting']],
  ['Cash Before Growth', 'Louis Peyrefitte', 2016, ['finance', 'working-capital']],
  ['Service Levels, Plainly', 'Noor Haddad', 2023, ['service', 'kpi']],
  ['The Cold Chain Handbook', 'Bastien Ferrandou', 2020, ['refrigeration', 'quality']],
  ['Small Firms, Big Suppliers', 'Clara Witteveen', 2021, ['sourcing', 'negotiation']],
  ['Lead Time Is a Distribution', 'Owen Thackeray', 2022, ['inventory', 'forecasting']],
  ['Teams That Decide', 'Aurore Delacombe', 2019, ['leadership', 'decision-making']],
];
const BOOK_THEMES = ['Inventory', 'Sourcing', 'Service', 'Working Capital', 'Lean', 'Negotiation',
  'Forecasting', 'Warehousing', 'Pricing', 'Change', 'Quality', 'Logistics'];
const BOOK_FORMS = ['{t} for Distributors', 'Practical {t}', '{t} in Small Firms', 'The {t} Playbook',
  'Rethinking {t}', '{t}: A Field Guide'];
const TOPICS = ['dual sourcing', 'safety stock', 'cycle counting', 'lead-time variability', 'service contracts',
  'spare-parts kitting', 'the cash conversion cycle', 'payment terms', 'seasonal demand', 'supplier scorecards',
  'warehouse slotting', 'blast chiller maintenance', 'refrigerant rules', 'technician route planning',
  'S&OP in a small firm', 'quarterly price reviews', 'credit checks', 'customer lifetime value',
  'returns handling', 'ABC analysis', 'hotel procurement', 'school canteen tenders', 'kitchen energy costs',
  'negotiating with manufacturers', 'change on the shop floor', 'KPI dashboards', 'technician on-call rotas'];
const ARTICLE_FORMS = ['Why {t} fails in small distributors', 'Five lessons on {t}', '{t}: a field guide',
  'What chefs expect from {t}', 'The hidden cost of ignoring {t}', 'A one-page method for {t}'];
const OUTLETS = [['Rhône Ops Review', 'ops-review'], ['Cuisine Pro Hebdo', 'cuisinepro-hebdo'],
  ['Distribution Today', 'distribution-today'], ['The Service Manager', 'service-manager'],
  ['Lyon Business Journal', 'lyon-business-journal']];
const JOURNALS = ['Journal of Operations Practice', 'Small Business Supply Review', 'Service Operations Quarterly'];
// [filename, company, topic tag]
const FILES = [
  ['frigeco-delivery-log-2025.xlsx', 'Frigeco Industrie', 'sourcing'], ['nordval-trial-order-report.pdf', 'Nordval Froid', 'sourcing'],
  ['supplier-scorecard-q2.pdf', 'Frigeco Industrie', 'sourcing'], ['reorder-rule-simulation.xlsx', null, 'reorder-policy'],
  ['varenne-framework-contract-draft.docx', 'Hôtel Varenne', 'key-accounts'], ['varenne-banquet-kitchen-plan.pdf', 'Hôtel Varenne', 'key-accounts'],
  ['stock-count-sheet-template.xlsx', null, 'cycle-counting'], ['service-van-kit-list.pdf', null, 'service'],
  ['cash-forecast-13-weeks.xlsx', null, 'working-capital'], ['price-review-checklist.pdf', null, 'pricing'],
];

// Tag -> index into academy SUBJECTS, so a note cites what it is about.
const SUBJECT_TAGS = [
  ['sourcing', 'supplier-risk', 'negotiation', 'logistics', 'dual-sourcing', 'supplier-scorecards',
    'negotiating-with-manufacturers', 'hotel-procurement', 'school-canteen-tenders'],
  ['inventory', 'reorder-policy', 'forecasting', 'warehousing', 'cycle-counting', 'safety-stock',
    'lead-time-variability', 'seasonal-demand', 'abc-analysis'],
  ['finance', 'costing', 'working-capital', 'pricing', 'the-cash-conversion-cycle', 'payment-terms',
    'quarterly-price-reviews', 'credit-checks', 'kitchen-energy-costs'],
  ['lean', 'quality', 'refrigeration', 'warehouse', 'warehouse-slotting', 'returns-handling',
    'blast-chiller-maintenance', 'refrigerant-rules', 'kpi-dashboards'],
  ['service', 'contracts', 'kpi', 'key-accounts', 'service-contracts', 'spare-parts-kitting',
    'technician-route-planning', 'technician-on-call-rotas', 'customer-lifetime-value'],
  ['leadership', 'decision-making', 'change', 's-op-in-a-small-firm', 'change-on-the-shop-floor'],
];

export function subjectIndexOf(item) {
  const found = SUBJECT_TAGS.findIndex((tags) => item.tags.some((t) => tags.includes(t)));
  return found === -1 ? SUBJECT_TAGS.length - 1 : found;
}
const MIME = { xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', pdf: 'application/pdf',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' };

function isbn13(rng) {
  const body = `97910${rng.int(90000, 99999)}${String(rng.int(0, 99)).padStart(2, '0')}`;
  const sum = [...body].reduce((acc, d, i) => acc + Number(d) * (i % 2 === 0 ? 1 : 3), 0);
  const check = (10 - (sum % 10)) % 10;
  return `${body.slice(0, 3)}-${body.slice(3, 5)}-${body.slice(5, 10)}-${body.slice(10)}-${check}`;
}

function author(rng) {
  return `${rng.pick(FIRST_NAMES)} ${rng.pick(LAST_NAMES)}`;
}

function base(n, kind, title, authors, year, tags, addedOn) {
  return { _id: idFor('library', `${kind}:${n}:${title}`), kind, title, authors, year, tags, added_on: addedOn, cited_in: [] };
}

export function buildLibrary({ seed, anchor }, idx) {
  const rng = forkRng(seed, 'library');
  const items = [];
  const added = () => addDays(anchor, -rng.int(5, 540));
  for (const [title, by, year, tags] of BOOKS) {
    items.push({ ...base(items.length, 'book', title, [by], year, tags, added()), isbn: isbn13(rng) });
  }
  const titles = new Set(items.map((i) => i.title));
  // make() returns [title, topic] and re-draws both on each try, so a topic whose forms are
  // all used cannot pin the loop.
  const unique = (make) => {
    for (;;) {
      const [title, topic] = make();
      if (!titles.has(title)) {
        titles.add(title);
        return [title, topic];
      }
    }
  };
  while (items.length < 60) {
    const [title, theme] = unique(() => {
      const t = rng.pick(BOOK_THEMES);
      return [rng.pick(BOOK_FORMS).replace('{t}', t), t];
    });
    items.push({ ...base(items.length, 'book', title, [author(rng)], rng.int(2008, 2025), [slug(theme)], added()), isbn: isbn13(rng) });
  }
  while (items.length < 170) {
    const [title, topic] = unique(() => {
      const t = rng.pick(TOPICS);
      return [rng.pick(ARTICLE_FORMS).replace('{t}', t).replace(/^./, (c) => c.toUpperCase()), t];
    });
    const [outlet, host] = rng.pick(OUTLETS);
    items.push({
      ...base(items.length, 'article', title, [author(rng)], rng.int(2019, 2026), [slug(topic)], added()),
      outlet, url: `https://${host}.example.com/${slug(title)}`,
    });
  }
  while (items.length < 215) {
    const [title, topic] = unique(() => {
      const t = rng.pick(TOPICS);
      return [`An empirical study of ${t} in ${rng.pick(['SME distributors', 'food-service supply chains', 'field service firms'])}`, t];
    });
    items.push({
      ...base(items.length, 'paper', title, [author(rng), author(rng)], rng.int(2012, 2025), [slug(topic), 'research'], added()),
      journal: rng.pick(JOURNALS), doi: `10.5555/ops.${rng.int(10000, 99999)}.${items.length}`,
    });
  }
  for (let n = 0; items.length < 250; n += 1) {
    const [name, companyName, topicTag] = FILES[n % FILES.length];
    const filename = n < FILES.length ? name : name.replace(/(\.\w+)$/, `-v${Math.floor(n / FILES.length) + 1}$1`);
    const ext = filename.split('.').pop();
    items.push({
      ...base(items.length, 'file', filename, ['Inès Caradec'], 2026, ['internal', topicTag], added()),
      filename, mime: MIME[ext], size_bytes: rng.int(18000, 2400000),
      company_id: companyName ? idx.companyByName.get(companyName).id : null,
    });
  }
  return items;
}

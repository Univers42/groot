// CRM rows: companies, contacts, company↔contact roles, deals and deal↔contact links.
// Returns the rows plus an index the trade, activity and page generators read their links from.
import { idFor } from './uuid.mjs';
import { forkRng, addDays, slug } from './prng.mjs';
import {
  COMPANIES, NAMED_PEOPLE, FIRST_NAMES, LAST_NAMES, STAFF_TITLES, STAFF_PER_DEPARTMENT,
  CLIENT_TITLES, SUPPLIER_TITLES,
} from './names.mjs';

const CLIENT_ROLES = Object.keys(CLIENT_TITLES);
const SUPPLIER_ROLES = Object.keys(SUPPLIER_TITLES);
const CONTACT_TOTAL = 220;

function buildCompanies(rng, anchor) {
  return COMPANIES.map(([name, kind, segment, city, postcode]) => {
    const isVarenne = name === 'Hôtel Varenne';
    let terms = 30;
    if (kind === 'self') terms = 0;
    else if (segment === 'collective_catering') terms = 60;
    else if (kind === 'supplier' || rng.chance(0.4)) terms = 45;
    let limit = 0;
    if (kind === 'client') limit = isVarenne ? 15000000 : rng.int(5, 80) * 100000;
    return {
      id: idFor('companies', slug(name)), name, kind, segment, city, postcode,
      email_domain: kind === 'self' ? 'arlet.example.com' : `${slug(name)}.example.com`,
      payment_terms_days: terms, credit_limit_eur: limit,
      relationship_since: addDays(anchor, -rng.int(400, 4200)),
    };
  });
}

function makeNamer(rng) {
  const used = new Set(NAMED_PEOPLE.map(([f, l]) => `${f} ${l}`));
  return () => {
    for (;;) {
      const first = rng.pick(FIRST_NAMES);
      const last = rng.pick(LAST_NAMES);
      if (!used.has(`${first} ${last}`)) {
        used.add(`${first} ${last}`);
        return [first, last];
      }
    }
  };
}

// How many contacts each non-Arlet company gets, summing to exactly CONTACT_TOTAL minus staff.
function contactQuota(rng, companies, staffCount) {
  const quota = new Map();
  for (const c of companies) {
    if (c.kind === 'client') quota.set(c.name, c.name === 'Hôtel Varenne' ? 8 : 3);
    if (c.kind === 'supplier') quota.set(c.name, 3);
    if (c.kind === 'partner') quota.set(c.name, 1);
  }
  const growable = companies.filter((c) => c.kind === 'client' && c.name !== 'Hôtel Varenne')
    .concat(companies.filter((c) => c.kind === 'partner'));
  let total = [...quota.values()].reduce((a, b) => a + b, 0) + staffCount;
  while (total < CONTACT_TOTAL) {
    const company = rng.pick(growable);
    const cap = company.kind === 'partner' ? 2 : 6;
    if (quota.get(company.name) < cap) {
      quota.set(company.name, quota.get(company.name) + 1);
      total += 1;
    }
  }
  return quota;
}

function personRow(ctx, [first, last], company, extra) {
  const local = `${slug(first)}.${slug(last)}`.replace(/-/g, '');
  const phoneTail = String(ctx.phones.pop()).padStart(4, '0');
  return {
    id: idFor('contacts', `${local}@${company.email_domain}`), company_id: company.id,
    first_name: first, last_name: last, email: `${local}@${company.email_domain}`,
    phone: `+33 6 39 98 ${phoneTail.slice(0, 2)} ${phoneTail.slice(2)}`,
    job_title: extra.title, department: extra.department ?? null,
    created_on: addDays(ctx.anchor, -ctx.rng.int(30, 1500)),
  };
}

function buildContacts(rng, anchor, companies) {
  const byName = new Map(companies.map((c) => [c.name, c]));
  const ctx = { rng, anchor, phones: rng.sample([...Array(10000).keys()], CONTACT_TOTAL) };
  const nextName = makeNamer(rng);
  const contacts = [];
  const primaryRole = new Map();
  const add = (name, company, title, department, role) => {
    const row = personRow(ctx, name, company, { title, department });
    contacts.push(row);
    primaryRole.set(row.id, role);
    return row;
  };
  for (const [first, last, companyName, title, department] of NAMED_PEOPLE) {
    const company = byName.get(companyName);
    let role = 'staff';
    if (company.kind === 'client') role = title === 'Executive chef' ? 'head_chef' : 'buyer';
    if (company.kind === 'supplier') role = 'sales_rep';
    if (company.kind === 'partner') role = 'account_manager';
    add([first, last], company, title, department, role);
  }
  const arlet = companies[0];
  for (const [department, count] of Object.entries(STAFF_PER_DEPARTMENT)) {
    for (let i = 0; i < count; i += 1) {
      add(nextName(), arlet, STAFF_TITLES[department][i % STAFF_TITLES[department].length], department, 'staff');
    }
  }
  const quota = contactQuota(rng, companies, contacts.filter((c) => c.company_id === arlet.id).length);
  for (const company of companies) {
    const already = contacts.filter((c) => c.company_id === company.id).length;
    for (let i = already; i < (quota.get(company.name) || 0); i += 1) {
      let role = 'account_manager';
      let title = 'Account manager';
      if (company.kind === 'client') role = CLIENT_ROLES[i % CLIENT_ROLES.length];
      if (company.kind === 'supplier') role = SUPPLIER_ROLES[i % SUPPLIER_ROLES.length];
      if (company.kind === 'client') title = CLIENT_TITLES[role];
      if (company.kind === 'supplier') title = SUPPLIER_TITLES[role];
      add(nextName(), company, title, null, role);
    }
  }
  return { contacts, primaryRole };
}

function buildRoles(rng, anchor, idx) {
  const rows = [];
  const add = (company, contact, role) => {
    rows.push({
      id: idFor('company_contacts', `${company.id}:${contact.id}:${role}`), company_id: company.id,
      contact_id: contact.id, role, since_on: addDays(anchor, -rng.int(20, 1400)),
    });
  };
  for (const contact of idx.contacts) add(idx.companyById.get(contact.company_id), contact, idx.primaryRole.get(contact.id));
  const sales = idx.staff.sales;
  const techs = idx.staff.service;
  idx.clients.forEach((client, i) => {
    const manager = client.name === 'Hôtel Varenne' ? sales[0] : sales[i % sales.length];
    idx.accountManager.set(client.id, manager);
    add(client, manager, 'arlet_account_manager');
    if (i < 30) add(client, techs[i % techs.length], 'arlet_technician');
  });
  const buyers = idx.staff.warehouse.filter((s) => s.job_title === 'Buyer');
  idx.suppliers.forEach((supplier, i) => {
    const refrigeration = supplier.segment === 'refrigeration_maker';
    add(supplier, refrigeration ? idx.people.ines : buyers[i % buyers.length], 'arlet_buyer');
  });
  return rows;
}

const DEAL_TOPICS = {
  hotel: ['Banquet kitchen extension', 'Room-service pantry refit', 'Breakfast buffet line', 'Cold room replacement'],
  restaurant: ['Kitchen refit', 'Hot line upgrade', 'Dishwashing area redesign', 'Terrace bar fit-out'],
  caterer: ['Production kitchen expansion', 'Blast-chilling capacity', 'Vacuum-packing line'],
  collective_catering: ['Central kitchen modernisation', 'Tray-line refrigeration', 'Dishwashing tunnel'],
  bakery: ['Pastry lab refrigeration', 'Shop display cabinets', 'Proofing room upgrade'],
  bar: ['Bar refrigeration refit', 'Glasswasher and ice station'],
};
const STAGES = [['won', 30, 100], ['lost', 14, 0], ['lead', 8, 10], ['qualified', 10, 25],
  ['proposal', 10, 50], ['negotiation', 8, 70]];

function buildDeals(rng, anchor, idx) {
  const stages = rng.sample(STAGES.flatMap(([s, n, p]) => Array.from({ length: n }, () => [s, p])), 80);
  const deals = [];
  const links = [];
  const weight = (c) => (c.name === 'Hôtel Varenne' ? 7 : 1 + (c.credit_limit_eur / 4000000));
  stages.forEach(([stage, probability], n) => {
    const company = n < 5 ? idx.varenne : rng.weighted(idx.clients, weight);
    const closed = stage === 'won' || stage === 'lost';
    const opened = closed ? addDays(anchor, -rng.int(80, 520)) : addDays(anchor, -rng.int(5, 150));
    const closedOn = closed ? addDays(opened, rng.int(20, 75)) : null;
    const topic = n === 0 ? 'Banquet kitchen extension' : rng.pick(DEAL_TOPICS[company.segment]);
    const base = company.name === 'Hôtel Varenne' ? rng.int(40, 190) : rng.int(3, 60);
    const deal = {
      id: idFor('deals', n), company_id: company.id, owner_contact_id: idx.accountManager.get(company.id).id,
      title: `${topic} — ${company.name}`, stage, amount_eur: base * 100000 + rng.int(0, 99) * 1000,
      probability_pct: probability, opened_on: opened,
      expected_close_on: closed ? closedOn : addDays(anchor, rng.int(10, 120)), closed_on: closedOn,
    };
    deals.push(deal);
    const people = idx.contactsByCompany.get(company.id);
    const chosen = company.name === 'Hôtel Varenne'
      ? [idx.people.marc, ...rng.sample(people.filter((p) => p !== idx.people.marc), rng.int(1, 3))]
      : rng.sample(people, Math.min(people.length, rng.int(2, 3)));
    const roles = ['decision_maker', ...rng.sample(['champion', 'influencer', 'technical', 'finance'], 3)];
    chosen.forEach((contact, i) => links.push({
      id: idFor('deal_contacts', `${deal.id}:${contact.id}`), deal_id: deal.id, contact_id: contact.id, role: roles[i],
    }));
  });
  return { deals, links };
}

export function buildCrm({ seed, anchor }) {
  const rng = forkRng(seed, 'crm');
  const companies = buildCompanies(rng, anchor);
  const { contacts, primaryRole } = buildContacts(rng, anchor, companies);
  const byFullName = new Map(contacts.map((c) => [`${c.first_name} ${c.last_name}`, c]));
  const contactsByCompany = new Map(companies.map((c) => [c.id, []]));
  for (const contact of contacts) contactsByCompany.get(contact.company_id).push(contact);
  const arletStaff = contactsByCompany.get(companies[0].id);
  const idx = {
    companies, contacts, primaryRole, contactsByCompany,
    companyById: new Map(companies.map((c) => [c.id, c])),
    companyByName: new Map(companies.map((c) => [c.name, c])),
    clients: companies.filter((c) => c.kind === 'client'),
    suppliers: companies.filter((c) => c.kind === 'supplier'),
    partners: companies.filter((c) => c.kind === 'partner'),
    varenne: companies.find((c) => c.name === 'Hôtel Varenne'),
    staff: Object.fromEntries(Object.keys(STAFF_PER_DEPARTMENT).map((d) => [d, arletStaff.filter((s) => s.department === d)])),
    accountManager: new Map(),
    people: {
      ines: byFullName.get('Inès Caradec'), jules: byFullName.get('Jules Marchand'),
      helene: byFullName.get('Hélène Arlet'), marc: byFullName.get('Marc Delorme'),
      sophie: byFullName.get('Sophie Lambertin'), thierry: byFullName.get('Thierry Gauvain'),
      camille: byFullName.get('Camille Royer'), agnes: byFullName.get('Agnès Pellerin'),
    },
  };
  const companyContacts = buildRoles(rng, anchor, idx);
  const { deals, links } = buildDeals(rng, anchor, idx);
  idx.deals = deals;
  return {
    rows: { companies, contacts, company_contacts: companyContacts, deals, deal_contacts: links },
    idx,
  };
}

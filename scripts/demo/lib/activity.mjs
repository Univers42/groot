// Interactions (Mongo collection `interactions`): calls, emails and meetings. One document per
// event, shape by kind: a call has duration_s, an email a subject and thread_id, a meeting
// attendees. Each references CRM uuids: contact, company, the Arlet owner, and the deal open at the time.
import { idFor } from './uuid.mjs';
import { forkRng, addDays, daysBetween, isWeekday, timestamp } from './prng.mjs';

const TOTAL = 700;

const NOTES = {
  client: {
    call: ['Asked for a lead time on {product}; promised an answer by Friday.',
      'Follow-up on the {product} installed last month: running well, chef happy.',
      'Called about an invoice query; resent the delivery note.',
      'Breakdown call: {product} not holding temperature, technician booked for tomorrow morning.'],
    meeting: ['Walked the kitchen with the chef to measure for {product}.',
      'Quarterly review: order volumes, open service tickets, next season.',
      'Showroom demo of {product}; they want a trial week.'],
  },
  supplier: {
    call: ['Chased a late delivery of {product}; new date promised, again.',
      'Agreed a firm delivery window for the next {product} batch.',
      'Price list update for next quarter discussed.'],
    meeting: ['Supplier review: on-time delivery, quality incidents, price.', 'Factory visit and trial-order debrief.'],
  },
  partner: {
    call: ['Checked the monthly statement against the contract.', 'Discussed renewal terms for next year.'],
    meeting: ['Annual account review.'],
  },
};
// [subject, note]: an email's note says what its subject announces.
const EMAILS = {
  client: [['Quote request — {product}', 'Sent the quote for {product} with the extended warranty option.'],
    ['Delivery slot confirmation', 'Confirmed the delivery slot before service, 7:30, rear entrance.'],
    ['Service visit report', 'Shared the technician’s report and the maintenance schedule for the coming quarter.'],
    ['Invoice copy', 'Resent the invoice copy with the signed delivery note.'],
    ['Kitchen refit — next steps', 'Sent the revised layout and the installation timeline.']],
  supplier: [['Delivery schedule', 'Asked for the revised delivery schedule in writing.'],
    ['Forecast — next 8 weeks', 'Sent the forecast for the next eight weeks.'],
    ['Price list update', 'Asked for next quarter’s price list.'],
    ['Late delivery — PO follow-up', 'Chased the overdue purchase order for {product}.']],
  partner: [['Monthly statement', 'Asked for a corrected statement.'], ['Contract renewal', 'Sent the signed renewal.'],
    ['Course schedule', 'Confirmed the next session dates.']],
};
const REPLIES = ['Replied with the requested details.', 'Confirmed on our side; nothing further needed.',
  'Answered the follow-up questions.'];
const CLIENT_CATEGORIES = new Set(['cooking', 'refrigeration', 'dishwashing', 'preparation', 'ventilation']);

// Clients talk about equipment; a supplier only about what it supplies.
function productFor(rng, ctx, company) {
  const pool = company.kind === 'supplier'
    ? ctx.products.filter((p) => p.supplier_id === company.id || p.second_supplier_id === company.id)
    : ctx.products.filter((p) => CLIENT_CATEGORIES.has(p.category));
  return rng.pick(pool).name;
}

function counterparty(rng, idx) {
  const roll = rng.next();
  if (roll < 0.18) return rng.chance(0.4) ? idx.varenne : rng.pick(idx.clients);
  if (roll < 0.75) return rng.pick(idx.clients);
  if (roll < 0.95) return rng.chance(0.5) ? rng.pick(idx.suppliers.slice(0, 2)) : rng.pick(idx.suppliers);
  return rng.pick(idx.partners);
}

function ownerFor(rng, idx, company) {
  if (company.kind === 'client') return rng.chance(0.75) ? idx.accountManager.get(company.id) : rng.pick(idx.staff.service);
  if (company.kind === 'supplier') return company.segment === 'refrigeration_maker' ? idx.people.ines : rng.pick(idx.staff.warehouse);
  return rng.chance(0.5) ? idx.people.jules : idx.people.ines;
}

function openDeal(rng, idx, company, day) {
  const open = idx.deals.filter((d) => d.company_id === company.id && d.opened_on <= day && (d.closed_on || '9999') >= day);
  return open.length > 0 && rng.chance(0.85) ? rng.pick(open) : null;
}

function noteFor(rng, ctx, company, kind, day) {
  const product = company.kind === 'partner' ? '' : productFor(rng, ctx, company);
  if (company.name === 'Frigeco Industrie' && kind === 'call' && day < ctx.story.switchOn) {
    return `Chased a late delivery of ${product}: ${rng.int(9, 21)} days behind the confirmed date. Third time this quarter.`;
  }
  if (company.name === 'Nordval Froid' && day >= ctx.story.switchOn && rng.chance(0.5)) {
    return `Trial order of ${product} delivered on the promised day. Second source working as planned.`;
  }
  return rng.pick(NOTES[company.kind][kind]).replace('{product}', product);
}

function emailFields(rng, ctx, company, contact, day, threads) {
  const previous = threads.get(contact.id);
  const reply = previous && daysBetween(previous.day, day) <= 14 && rng.chance(0.6);
  let subject;
  let notes;
  if (reply) {
    subject = `Re: ${previous.subject.replace(/^Re: /, '')}`;
    notes = rng.pick(REPLIES);
  } else {
    const product = company.kind === 'partner' ? '' : productFor(rng, ctx, company);
    [subject, notes] = rng.pick(EMAILS[company.kind]).map((t) => t.replace('{product}', product));
  }
  const threadId = reply ? previous.thread_id : idFor('threads', `${contact.id}:${day}:${threads.size}`);
  threads.set(contact.id, { day, subject, thread_id: threadId });
  return { notes, direction: rng.chance(0.5) ? 'inbound' : 'outbound', subject, thread_id: threadId };
}

function interaction(rng, ctx, day, threads) {
  const idx = ctx.idx;
  const company = counterparty(rng, idx);
  const people = idx.contactsByCompany.get(company.id);
  const contact = company === idx.varenne && rng.chance(0.6) ? idx.people.marc : rng.pick(people);
  const owner = ownerFor(rng, idx, company);
  const kind = rng.weighted([['email', 45], ['call', 35], ['meeting', 20]], ([, w]) => w)[0];
  const deal = company.kind === 'client' ? openDeal(rng, idx, company, day) : null;
  const doc = {
    _id: null, kind, occurred_at: timestamp(day, rng.int(8 * 60, 18 * 60)), company_id: company.id,
    contact_id: contact.id, owner_contact_id: owner.id, deal_id: deal ? deal.id : null,
    notes: kind === 'email' ? null : noteFor(rng, ctx, company, kind, day),
  };
  if (kind === 'call') Object.assign(doc, { direction: rng.chance(0.5) ? 'inbound' : 'outbound', duration_s: rng.int(45, 1500) });
  if (kind === 'meeting') {
    const extra = rng.sample(people.filter((p) => p !== contact), rng.int(0, 2));
    Object.assign(doc, {
      location: rng.chance(0.6) ? `${company.name}, ${company.city}` : 'Arlet showroom, Vénissieux',
      duration_min: rng.pick([30, 45, 60, 90]), attendees: [contact.id, owner.id, ...extra.map((p) => p.id)],
    });
  }
  if (kind === 'email') Object.assign(doc, emailFields(rng, ctx, company, contact, day, threads));
  return doc;
}

export function buildInteractions({ seed, anchor }, idx, products, story) {
  const rng = forkRng(seed, 'activity');
  const ctx = { idx, products, story };
  const start = addDays(anchor, -540);
  const days = [];
  for (let day = start; day < anchor; day = addDays(day, 1)) if (isWeekday(day)) days.push(day);
  const picked = Array.from({ length: TOTAL }, () => rng.pick(days)).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const threads = new Map();
  const docs = picked.map((day) => interaction(rng, ctx, day, threads));
  // The standalone spike needs a Marc call without a deal; random draws alone cannot
  // guarantee it. Keep the count and full/spike identity stable for every seed.
  if (!docs.some((d) => d.contact_id === idx.people.marc.id && d.kind === 'call' && d.deal_id === null)) {
    docs[0] = {
      _id: null, kind: 'call', occurred_at: docs[0].occurred_at, company_id: idx.varenne.id,
      contact_id: idx.people.marc.id, owner_contact_id: idx.accountManager.get(idx.varenne.id).id,
      deal_id: null, notes: 'Called about an invoice query; resent the delivery note.',
      direction: 'inbound', duration_s: 300,
    };
  }
  docs.sort((a, b) => (a.occurred_at < b.occurred_at ? -1 : a.occurred_at > b.occurred_at ? 1 : 0));
  docs.forEach((doc, n) => { doc._id = idFor('interactions', n); });
  return docs;
}

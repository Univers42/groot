// The academy pages: a certificate root, one page per subject, and 120 signed notes under them.
// Each note informs one decision (relation `informs`, reverse `informed_by` on the decision),
// is related to the previous session of its course (both sides), cites library items by uuid,
// and names the people it involves by contact uuid.
import { addDays, slug } from './prng.mjs';
import { CERTIFICATE, SUBJECTS } from './academy.mjs';
import { HUB_BOOK, subjectIndexOf } from './library.mjs';
import { text, date, select, tags, relation, uuidList, blocks, page, addReverse } from './page-format.mjs';

const DEPARTMENT_BY_SUBJECT = ['warehouse', 'warehouse', 'finance', 'warehouse', 'service', 'sales'];
const HUB_QUOTES = ['One supplier is a dependency; two suppliers are a choice.',
  'Split the volume before the crisis, not during it.',
  'The second source earns its price premium on the worst week of the year.',
  'Tell the first supplier before you call the second.'];
const ACTIONS = ['Share with Jules before Monday’s S&OP', 'Check the numbers in the trade reports',
  'Bring this to the next supplier review', 'Add this to the S&OP agenda'];

export const ACADEMY_ROOT = 'academy';

export function subjectKey(subject) {
  return `subject-${slug(subject.name)}`;
}

// Skeletons first, so library items can be spread over every note before any page is written.
export function noteSkeletons(ctx) {
  const out = [];
  const start = addDays(ctx.anchor, -450);
  const span = 430;
  let n = 0;
  SUBJECTS.forEach((subject, si) => subject.courses.forEach((course, ci) => course.topics.forEach(([title, idea], ti) => {
    const decisionOn = ctx.decisionDates[course.decision];
    let day = addDays(start, Math.round((n * span) / 120));
    if (day >= decisionOn) day = addDays(decisionOn, -ctx.rng.int(3, 30) - (4 - ti));
    if (day < start) day = addDays(start, ti);
    out.push({
      seedKey: `note-${slug(subject.name)}-${String(ci * 5 + ti + 1).padStart(2, '0')}`,
      subject, subjectIndex: si, course, session: ti + 1, title, idea, day, decision: course.decision, library: [],
    });
    n += 1;
  })));
  return out;
}

export function assignLibrary(rng, notes, library) {
  const hub = library.find((item) => item.title === HUB_BOOK);
  for (const note of notes) if (note.decision === 'supplier-switch') note.library.push(hub);
  const groups = SUBJECTS.map(() => []);
  for (const item of rng.sample(library.filter((i) => i !== hub), library.length - 1)) groups[subjectIndexOf(item)].push(item);
  // First pass: every note cites one item, its own subject's when there is one left.
  for (const note of notes) {
    const own = groups[note.subjectIndex];
    const donor = own.length > 0 ? own : groups.reduce((a, b) => (b.length > a.length ? b : a));
    note.library.push(donor.shift());
  }
  // Second pass: the rest round-robin within their subject.
  groups.forEach((items, subject) => {
    const pool = notes.filter((note) => note.subjectIndex === subject);
    items.forEach((item, n) => pool[n % pool.length].library.push(item));
  });
}

function peopleFor(ctx, note) {
  const decision = ctx.decisionBySlug[note.decision];
  const named = decision.people.map((key) => ctx.idx.people[key]);
  const companies = decision.companies.map((name) => ctx.idx.companyByName.get(name));
  const fromCompany = companies.length > 0 ? ctx.idx.contactsByCompany.get(companies[0].id)[0] : null;
  const staff = ctx.rng.pick(ctx.idx.staff[DEPARTMENT_BY_SUBJECT[note.subjectIndex]]);
  const pool = [...named, fromCompany, staff].filter(Boolean);
  return [...new Set(ctx.rng.sample(pool, ctx.rng.int(1, 2)))];
}

function personLabel(ctx, contact) {
  return `${contact.first_name} ${contact.last_name} (${ctx.idx.companyById.get(contact.company_id).name})`;
}

function noteContent(ctx, note, previous, people) {
  const decisionKey = `decision-${note.decision}`;
  const decision = ctx.decisionBySlug[note.decision];
  const cited = note.library[0];
  const bridge = [`This fed into [[seed:${decisionKey}]]. ${decision.context}`,
    `Applied in [[seed:${decisionKey}]]: ${decision.summary}`,
    `Why it matters for [[seed:${decisionKey}]]: ${decision.outcome}`][note.session % 3];
  const quote = cited.title === HUB_BOOK
    ? `“${HUB_QUOTES[note.session % HUB_QUOTES.length]}” — ${cited.authors[0]}, ${cited.title}`
    : `“${note.idea}” — ${ctx.idx.people.agnes.first_name} ${ctx.idx.people.agnes.last_name}, in class`;
  const specs = [
    ['callout', `${CERTIFICATE} · ${note.subject.name} · ${note.course.name}, session ${note.session}. Signed: Inès Caradec, ${note.day}.`],
    ['heading_2', 'Key idea'], ['paragraph', note.idea],
    ['heading_2', 'At Arlet'], ['paragraph', bridge],
    ...people.map((c) => ['bulleted_list', `Talk to ${personLabel(ctx, c)}.`]),
    ...note.library.map((item) => ['bulleted_list', `Source: ${item.title} (${item.kind}).`]),
    ['quote', quote],
    ['to_do', ACTIONS[note.session % ACTIONS.length], note.day < addDays(ctx.anchor, -30)],
  ];
  if (previous) specs.push(['paragraph', `Previous session: [[seed:${previous.seedKey}]]`]);
  return blocks(note.seedKey, specs);
}

function notePage(ctx, note, previous) {
  const people = peopleFor(ctx, note);
  const subject = note.subject;
  return page({
    seedKey: note.seedKey, workspace: 'operations', title: note.title, icon: subject.icon, parent: subjectKey(subject),
    properties: [
      select('subject', 'Subject', subject.name, SUBJECTS.map((s) => s.name)),
      select('course', 'Course', note.course.name, subject.courses.map((c) => c.name)),
      { key: 'session', label: 'Session', type: 'number', value: note.session },
      text('signed_by', 'Signed by', 'Inès Caradec'), date('signed_on', 'Signed on', note.day),
      relation('informs', 'Informs', [`decision-${note.decision}`]),
      relation('related', 'Related notes', previous ? [previous.seedKey] : []),
      text('sources', 'Sources', note.library.map((i) => i.title).join('; ')),
      uuidList('library_ids', 'Library refs', note.library.map((i) => i._id)),
      text('people', 'People', people.map((c) => personLabel(ctx, c)).join('; ')),
      uuidList('contact_ids', 'People refs', people.map((c) => c.id)),
      tags(['academy', slug(subject.name), slug(note.course.name)]),
    ],
    content: noteContent(ctx, note, previous, people),
  });
}

export function academyPages(ctx, notes) {
  const root = page({
    seedKey: ACADEMY_ROOT, workspace: 'operations', title: CERTIFICATE, icon: '🎓',
    properties: [text('school', 'School', 'Institut Saône Management'), tags(['academy'])],
    content: blocks(ACADEMY_ROOT, [
      ['paragraph', `Inès Caradec’s notes from the ${CERTIFICATE.toLowerCase()}, one page per session, each signed and linked to the decision it informed.`],
      ...SUBJECTS.map((s) => ['bulleted_list', `[[seed:${subjectKey(s)}]]`]),
    ]),
  });
  const subjects = SUBJECTS.map((s) => page({
    seedKey: subjectKey(s), workspace: 'operations', title: s.name, icon: s.icon, parent: ACADEMY_ROOT,
    properties: [tags(['academy', slug(s.name)])],
    content: blocks(subjectKey(s), [
      ['heading_2', 'Courses'], ...s.courses.map((c) => ['bulleted_list', c.name]),
    ]),
  }));
  const pages = [];
  notes.forEach((note, i) => {
    const previous = i > 0 && notes[i - 1].course === note.course ? notes[i - 1] : null;
    const built = notePage(ctx, note, previous);
    if (previous) addReverse(pages[i - 1], 'related', 'Related notes', note.seedKey);
    pages.push(built);
  });
  return [root, ...subjects, ...pages];
}

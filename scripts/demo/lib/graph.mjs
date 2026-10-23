// The demo as one graph: every SQL row, Mongo document and page is a node, every
// reference an edge. integrityErrors() lists dangling references and missing reverse sides;
// linkGraph() measures links per record (distinct neighbours, so a forward field and its
// explicit reverse count once) and lists orphans. PLAN §5.3: average ≥ 3, zero orphans.
import { TABLES } from './tables.mjs';
import { pageRelations, inlineLinks, uuidMentions } from './page-format.mjs';

// Each reference as [fromNode, toNode, label]; toNode is null when the target does not exist.
function references(dataset) {
  const uuidNode = new Map();
  for (const t of TABLES) for (const row of dataset.tables[t.name]) uuidNode.set(row.id, `${t.name}:${row.id}`);
  for (const d of dataset.interactions) uuidNode.set(d._id, `interactions:${d._id}`);
  for (const d of dataset.library) uuidNode.set(d._id, `library:${d._id}`);
  const pageKeys = new Set(dataset.pages.map((p) => p.seed_key));
  const pageNode = (key) => (pageKeys.has(key) ? `pages:${key}` : null);
  const tableNode = (table, id) => (uuidNode.get(id) === `${table}:${id}` ? uuidNode.get(id) : null);
  const refs = [];
  for (const t of TABLES) {
    for (const row of dataset.tables[t.name]) {
      for (const c of t.columns) {
        if (c.fk && row[c.name] !== null) refs.push([`${t.name}:${row.id}`, tableNode(c.fk, row[c.name]), `${t.name}.${c.name}`]);
      }
    }
  }
  for (const d of dataset.interactions) {
    const from = `interactions:${d._id}`;
    for (const key of ['contact_id', 'owner_contact_id']) refs.push([from, tableNode('contacts', d[key]), `interactions.${key}`]);
    refs.push([from, tableNode('companies', d.company_id), 'interactions.company_id']);
    if (d.deal_id) refs.push([from, tableNode('deals', d.deal_id), 'interactions.deal_id']);
    for (const a of d.attendees || []) refs.push([from, tableNode('contacts', a), 'interactions.attendees']);
  }
  for (const d of dataset.library) {
    const from = `library:${d._id}`;
    if (d.company_id) refs.push([from, tableNode('companies', d.company_id), 'library.company_id']);
    for (const key of d.cited_in || []) refs.push([from, pageNode(key), 'library.cited_in']);
  }
  for (const p of dataset.pages) {
    const from = `pages:${p.seed_key}`;
    if (p.parent_seed_key) refs.push([from, pageNode(p.parent_seed_key), 'page.parent']);
    for (const key of pageRelations(p)) refs.push([from, pageNode(key), 'page.relation']);
    for (const key of inlineLinks(p)) refs.push([from, pageNode(key), 'page.inline_link']);
    for (const id of uuidMentions(p)) refs.push([from, uuidNode.get(id) || null, 'page.uuid_mention']);
  }
  return refs;
}

function reverseErrors(dataset) {
  const errors = [];
  const byKey = new Map(dataset.pages.map((p) => [p.seed_key, p]));
  for (const p of dataset.pages) {
    for (const key of pageRelations(p)) {
      const target = byKey.get(key);
      if (target && !pageRelations(target).includes(p.seed_key)) errors.push(`relation ${p.seed_key} → ${key} has no reverse`);
    }
  }
  const mentions = new Map(dataset.pages.map((p) => [p.seed_key, new Set(uuidMentions(p))]));
  for (const item of dataset.library) {
    for (const key of item.cited_in || []) {
      if (mentions.has(key) && !mentions.get(key).has(item._id)) errors.push(`library ${item._id} cited_in ${key} without a mention`);
    }
  }
  const itemById = new Map(dataset.library.map((i) => [i._id, i]));
  for (const p of dataset.pages) {
    for (const id of mentions.get(p.seed_key)) {
      const item = itemById.get(id);
      if (item && !(item.cited_in || []).includes(p.seed_key)) errors.push(`page ${p.seed_key} cites ${id} without cited_in`);
    }
  }
  return errors;
}

function consistencyErrors(dataset) {
  const contactCompany = new Map(dataset.tables.contacts.map((c) => [c.id, c.company_id]));
  return dataset.interactions
    .filter((d) => contactCompany.has(d.contact_id) && contactCompany.get(d.contact_id) !== d.company_id)
    .map((d) => `interaction ${d._id}: contact is not at company ${d.company_id}`);
}

export function integrityErrors(dataset) {
  const dangling = references(dataset).filter(([, to]) => to === null).map(([from, , label]) => `${label} from ${from} dangles`);
  return [...dangling, ...reverseErrors(dataset), ...consistencyErrors(dataset)];
}

export function nodeIds(dataset) {
  return [
    ...TABLES.flatMap((t) => dataset.tables[t.name].map((row) => `${t.name}:${row.id}`)),
    ...dataset.interactions.map((d) => `interactions:${d._id}`),
    ...dataset.library.map((d) => `library:${d._id}`),
    ...dataset.pages.map((p) => `pages:${p.seed_key}`),
  ];
}

export function linkGraph(dataset) {
  const nodes = nodeIds(dataset);
  const neighbours = new Map(nodes.map((n) => [n, new Set()]));
  for (const [from, to] of references(dataset)) {
    if (to === null || from === to || !neighbours.has(to)) continue;
    neighbours.get(from).add(to);
    neighbours.get(to).add(from);
  }
  let degrees = 0;
  for (const set of neighbours.values()) degrees += set.size;
  return {
    records: nodes.length,
    links: degrees / 2,
    average: nodes.length === 0 ? 0 : degrees / nodes.length,
    orphans: nodes.filter((n) => neighbours.get(n).size === 0),
  };
}

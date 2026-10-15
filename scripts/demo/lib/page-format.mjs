// The osionos page shape the loader posts verbatim (apps/osionos/app/src/entities/page/model/
// types.ts PagePropertyEntry; entities/block/model/types.ts Block). Relations hold "seed:<key>"
// and inline links are [[seed:<key>]]: the loader swaps both for server page ids.
import { createHash } from 'node:crypto';

// The loader's key grammar (scripts/demo/seed-links.mjs): lowercase letters, digits, dashes.
export const SEED_KEY = /^[a-z0-9][a-z0-9-]*$/;
export const SEED_LINK = /\[\[seed:([a-z0-9][a-z0-9-]*)\]\]/g;
export const RELATION_PREFIX = 'seed:';

export function text(key, label, value) {
  return { key, label, type: 'text', value };
}

export function date(key, label, value) {
  return { key, label, type: 'date', value };
}

export function select(key, label, value, options) {
  return { key, label, type: 'select', value, options };
}

export function tags(values) {
  return { key: 'tags', label: 'Tags', type: 'multi_select', value: values, options: values };
}

export function relation(key, label, seedKeys) {
  return { key, label, type: 'relation', relationTarget: 'page', value: seedKeys.map((k) => RELATION_PREFIX + k) };
}

// uuid mentions of mount records (library items, contacts, companies). page() moves them to the
// page's `refs`, which the generator's graph and integrity checks read and the loader never posts:
// as properties they put raw UUIDs on screen next to the names the page already shows (Sources,
// People, Companies), and osionos has no hidden property.
export function uuidList(key, _label, ids) {
  return { ref: key, ids };
}

export function blockId(seedKey, n) {
  return `b${createHash('sha1').update(`${seedKey}#${n}`).digest('hex').slice(0, 10)}`;
}

// specs: [type, content] or [type, content, checked] for to_do.
export function blocks(seedKey, specs) {
  return specs.map(([type, content, checked], n) => {
    const block = { id: blockId(seedKey, n), type, content, children: [] };
    if (type === 'to_do') block.checked = Boolean(checked);
    return block;
  });
}

export function page({ seedKey, workspace, title, icon, parent, extra, properties, content }) {
  if (!SEED_KEY.test(seedKey)) throw new Error(`page: seed key ${seedKey} is outside the loader's grammar`);
  const out = { seed_key: seedKey, workspace, title, icon };
  if (parent) out.parent_seed_key = parent;
  Object.assign(out, extra);
  out.properties = properties.filter((prop) => !prop.ref);
  out.refs = Object.fromEntries(properties.filter((prop) => prop.ref && prop.ids.length > 0).map((prop) => [prop.ref, prop.ids]));
  out.content = content;
  return out;
}

export function property(pageEntry, key) {
  return pageEntry.properties.find((p) => p.key === key);
}

// Every page this page names through a relation property, without the "seed:" prefix.
export function pageRelations(pageEntry) {
  return pageEntry.properties.filter((p) => p.type === 'relation')
    .flatMap((p) => p.value.map((v) => v.slice(RELATION_PREFIX.length)));
}

export function inlineLinks(pageEntry) {
  return pageEntry.content.flatMap((b) => [...b.content.matchAll(SEED_LINK)].map((m) => m[1]));
}

export function uuidMentions(pageEntry) {
  return Object.values(pageEntry.refs ?? {}).flat();
}

// Adds `from` to the reverse relation property on `target`, creating it when absent.
export function addReverse(target, key, label, from) {
  let prop = property(target, key);
  if (!prop) {
    prop = relation(key, label, []);
    target.properties.push(prop);
  }
  if (!prop.value.includes(RELATION_PREFIX + from)) prop.value.push(RELATION_PREFIX + from);
}

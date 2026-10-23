// seed-links.mjs — the pure half of the page loader: how a generated page's `seed:` references
// become server ids, and in which order pages can be created. The generator names every page by a
// deterministic seed_key; the server mints the ids (bridge-api.mjs pageCreateRowFromPayload), so
// links are written as [[seed:<key>]] and relation values as "seed:<key>" until the id is known.

import { isDeepStrictEqual } from 'node:util';

const INLINE = /\[\[seed:([a-z0-9][a-z0-9-]*)\]\]/g;
const RELATION = /^seed:([a-z0-9][a-z0-9-]*)$/;

/** The text with every [[seed:k]] whose id is known turned into [[page:<id>]]. */
export function resolveText(text, ids) {
	return text.replace(INLINE, (whole, key) => (ids[key] ? `[[page:${ids[key]}]]` : whole));
}

/** A page's properties and content with every known seed reference resolved. */
export function resolvePage(page, ids) {
	return {
		properties: page.properties.map((prop) =>
			prop.type === 'relation' && Array.isArray(prop.value)
				? { ...prop, value: prop.value.map((v) => (RELATION.test(v) && ids[RELATION.exec(v)[1]] ? ids[RELATION.exec(v)[1]] : v)) }
				: prop,
		),
		content: page.content.map((block) => ({ ...block, content: resolveText(block.content ?? '', ids) })),
	};
}

/** Whether a stored page still carries a seed reference the loader has to resolve. */
export function hasSeedReference(page) {
	const inText = (page.content ?? []).some((block) => typeof block.content === 'string' && /\[\[seed:/.test(block.content));
	const inRelation = (page.properties ?? []).some((prop) => prop.type === 'relation' && Array.isArray(prop.value) && prop.value.some((v) => RELATION.test(v)));
	return inText || inRelation;
}

/** The seed_key a stored page carries as a property (pages loaded before 2026-10-16), or undefined. */
export function seedKeyOf(entry) {
	return (entry.properties ?? []).find((prop) => prop.key === 'seed_key')?.value;
}

/**
 * Which generated page a stored one is: by the manifest's id, by a legacy seed_key property, or,
 * for a page created by a run cut short before its manifest save, by title under the same parent
 * among pages the manifest does not hold yet. `ids` is the manifest's seed_key → id map.
 * Caveat: the title match assumes no one added a page with the same title under the same parent
 * in that window; such a page would be adopted as the seed's (it is never posted twice, never lost).
 */
export function pageKeyOf(entry, ids, pages) {
	const byId = Object.entries(ids).find(([, id]) => id === entry._id);
	if (byId) return byId[0];
	const legacy = seedKeyOf(entry);
	if (legacy) return legacy;
	const parentKey = Object.entries(ids).find(([, id]) => id === entry.parentPageId)?.[0];
	return pages.find((page) => !ids[page.seed_key] && page.title === entry.title && (page.parent_seed_key ?? null) === (parentKey ?? null))?.seed_key;
}

const LEGACY = (prop) => prop.key === 'seed_key' || /_ids$/.test(prop.key);

/**
 * The properties a page loaded before 2026-10-16 should now hold: the same, minus the seed_key
 * and the *_ids UUID lists that put raw ids on screen. null when the page holds none of them, or
 * when anything else differs from what the seed wrote, so an edit made in the app survives.
 */
export function reshapedProperties(stored, expected) {
	const properties = stored.properties ?? [];
	if (!properties.some(LEGACY)) return null;
	return isDeepStrictEqual(properties.filter((prop) => !LEGACY(prop)), expected) ? expected : null;
}

/** Pages ordered so each parent comes before its children; throws on a cycle or a missing parent. */
export function creationOrder(pages) {
	const byKey = new Map(pages.map((page) => [page.seed_key, page]));
	const ordered = [];
	const state = new Map();
	const visit = (page) => {
		if (state.get(page.seed_key) === 'done') return;
		if (state.get(page.seed_key) === 'open') throw new Error(`parent cycle at ${page.seed_key}`);
		state.set(page.seed_key, 'open');
		if (page.parent_seed_key) {
			const parent = byKey.get(page.parent_seed_key);
			if (!parent) throw new Error(`${page.seed_key}: parent ${page.parent_seed_key} is not in the set`);
			visit(parent);
		}
		state.set(page.seed_key, 'done');
		ordered.push(page);
	};
	pages.forEach(visit);
	return ordered;
}

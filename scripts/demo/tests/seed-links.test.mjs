import assert from 'node:assert/strict';
import { test } from 'node:test';
import { creationOrder, hasSeedReference, resolvePage, resolveText, seedKeyOf } from '../seed-links.mjs';

const ID = '0f1e2d3c-4b5a-4968-8776-655443322110';

test('a known inline link becomes a page link, an unknown one waits', () => {
	assert.equal(resolveText('See [[seed:supplier-switch]] and [[seed:later]].', { 'supplier-switch': ID }), `See [[page:${ID}]] and [[seed:later]].`);
});

test('relation values resolve, other properties are untouched', () => {
	const page = {
		properties: [
			{ key: 'informs', label: 'Informs', type: 'relation', value: ['seed:supplier-switch', 'seed:later'] },
			{ key: 'seed_key', label: 'Seed key', type: 'text', value: 'seed:not-a-relation' },
		],
		content: [{ id: 'b1', type: 'paragraph', content: '[[seed:supplier-switch]]', children: [] }],
	};
	const out = resolvePage(page, { 'supplier-switch': ID });
	assert.deepEqual(out.properties[0].value, [ID, 'seed:later']);
	assert.equal(out.properties[1].value, 'seed:not-a-relation');
	assert.equal(out.content[0].content, `[[page:${ID}]]`);
	assert.equal(hasSeedReference(out), true);
	assert.equal(hasSeedReference(resolvePage(page, { 'supplier-switch': ID, later: ID })), false);
});

test('the seed key is read back from a stored page', () => {
	assert.equal(seedKeyOf({ properties: [{ key: 'seed_key', value: 'note-1' }] }), 'note-1');
	assert.equal(seedKeyOf({ properties: [] }), undefined);
});

test('parents are created before their children, whatever the input order', () => {
	const pages = [{ seed_key: 'note-1', parent_seed_key: 'subject-a' }, { seed_key: 'subject-a', parent_seed_key: 'academy' }, { seed_key: 'academy' }];
	assert.deepEqual(creationOrder(pages).map((p) => p.seed_key), ['academy', 'subject-a', 'note-1']);
});

test('a missing parent or a cycle is refused', () => {
	assert.throws(() => creationOrder([{ seed_key: 'a', parent_seed_key: 'ghost' }]), /ghost is not in the set/);
	assert.throws(() => creationOrder([{ seed_key: 'a', parent_seed_key: 'b' }, { seed_key: 'b', parent_seed_key: 'a' }]), /cycle/);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hasSeedReference, resolvePage } from '../seed-links.mjs';
import { fixture } from './helpers.mjs';

const SEED_KEY = /^[a-z0-9][a-z0-9-]*$/;

test('every seed key is lowercase letters, digits and dashes', () => {
  for (const p of fixture().dataset.pages) assert.match(p.seed_key, SEED_KEY);
});

test('every page names its workspace; only the shared page is in finance', () => {
  const pages = fixture().dataset.pages;
  for (const p of pages) assert.ok(['operations', 'finance'].includes(p.workspace), p.seed_key);
  assert.deepEqual(pages.filter((p) => p.workspace === 'finance').map((p) => p.seed_key), ['q4-supplier-review']);
});

test('the shared page carries the loader fields', () => {
  const shared = fixture().dataset.pages.find((p) => p.seed_key === 'q4-supplier-review');
  assert.equal(shared.workspace, 'finance');
  assert.equal(shared.shared_with, 'jules');
});

// The loader's own parser, plus a broad scan: hasSeedReference only sees keys it can parse, so a
// malformed [[seed:…]] would slip past it but not past the leftover scan.
function leftovers(page, ids) {
  const resolved = resolvePage(page, ids);
  const inline = resolved.content.flatMap((b) => b.content.match(/\[\[seed:[^\]]*\]\]/g) || []);
  const relations = resolved.properties.filter((p) => p.type === 'relation').flatMap((p) => p.value)
    .filter((v) => String(v).startsWith('seed:'));
  return { parsed: hasSeedReference(resolved), left: [...inline, ...relations] };
}

function allIds(pages) {
  return Object.fromEntries(pages.map((p, i) => [p.seed_key, `00000000-0000-5000-8000-${String(i).padStart(12, '0')}`]));
}

test('the loader resolves every reference in every page', () => {
  const pages = fixture().dataset.pages;
  const ids = allIds(pages);
  for (const p of pages) assert.deepEqual(leftovers(p, ids), { parsed: false, left: [] }, p.seed_key);
});

test('a link the loader cannot parse is caught', () => {
  const pages = fixture().dataset.pages;
  const page = structuredClone(pages[0]);
  page.content.push({ id: 'bbad', type: 'paragraph', content: 'see [[seed:Bad:Key]]', children: [] });
  assert.deepEqual(leftovers(page, allIds(pages)).left, ['[[seed:Bad:Key]]']);
});

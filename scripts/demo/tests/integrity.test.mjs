import { test } from 'node:test';
import assert from 'node:assert/strict';
import { integrityErrors } from '../lib/graph.mjs';
import { pageRelations, RELATION_PREFIX } from '../lib/page-format.mjs';
import { fixture } from './helpers.mjs';

test('the generated dataset has no dangling reference', () => {
  assert.deepEqual(integrityErrors(fixture().dataset), []);
});

// Each mutation plants one defect in a copy; the check must name it, or it proves nothing.
const MUTATIONS = {
  'SQL foreign key': (d) => { d.tables.trade_order_lines[0].product_id = '00000000-0000-5000-8000-000000000000'; },
  'interaction contact': (d) => { d.interactions[0].contact_id = '00000000-0000-5000-8000-000000000001'; },
  'inline seed link': (d) => {
    d.pages[0].content.push({ id: 'bplanted', type: 'paragraph', content: 'see [[seed:note-missing-99]]', children: [] });
  },
  'missing reverse relation': (d) => {
    const from = d.pages.find((p) => pageRelations(p).length > 0);
    const target = d.pages.find((p) => p.seed_key === pageRelations(from)[0]);
    for (const prop of target.properties.filter((x) => x.type === 'relation')) {
      prop.value = prop.value.filter((v) => v !== RELATION_PREFIX + from.seed_key);
    }
  },
  'page property uuid': (d) => {
    const prop = d.pages.flatMap((p) => p.properties).find((x) => x.key === 'library_ids' && x.value);
    prop.value = '00000000-0000-5000-8000-000000000002';
  },
};

for (const [name, mutate] of Object.entries(MUTATIONS)) {
  test(`integrity check catches a planted ${name}`, () => {
    const copy = structuredClone(fixture().dataset);
    mutate(copy);
    assert.ok(integrityErrors(copy).length > 0);
  });
}

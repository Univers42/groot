import { test } from 'node:test';
import assert from 'node:assert/strict';
import { contactViolations } from '../lib/contact-rules.mjs';
import { fixture } from './helpers.mjs';

test('the check catches a planted real-looking email, phone and URL', () => {
  const planted = [
    'Call Paul on +33 6 12 34 56 78 or write paul@gmail.com',
    'see https://www.lyon-restaurants.fr/menu and ok@arlet.example.com +33 6 39 98 10 20',
  ].join('\n');
  const found = contactViolations(planted).map((v) => v.value);
  assert.deepEqual(found.sort(), ['+33 6 12 34 56 78', 'https://www.lyon-restaurants.fr', 'paul@gmail.com']);
});

test('allowed forms pass', () => {
  const ok = 'a.b@arlet.example.com x@hotel-varenne.example.com q@lab.test +33 6 39 98 00 07 https://ops-journal.example.com/a';
  assert.deepEqual(contactViolations(ok), []);
});

test('every generated file uses only fictional contact data', () => {
  const { files } = fixture();
  for (const [name, text] of Object.entries(files)) {
    assert.deepEqual(contactViolations(text), [], name);
  }
});

test('the generated data carries emails and phones at all (the check is not vacuous)', () => {
  const { files } = fixture();
  assert.match(files['crm.data.sql'], /'ines\.caradec@arlet\.example\.com'/);
  assert.match(files['crm.data.sql'], /'marc\.delorme@hotel-varenne\.example\.com'/);
  assert.match(files['crm.data.sql'], /'\+33 6 39 98 \d\d \d\d'/);
});

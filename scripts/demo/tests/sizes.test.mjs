import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dataStatements } from '../lib/render.mjs';
import { fixture } from './helpers.mjs';

const LIMIT = 200 * 1024;

test('every data statement is under 200 KB, and the big tables are chunked', () => {
  const statements = dataStatements(fixture().dataset);
  for (const s of statements) assert.ok(Buffer.byteLength(s) < LIMIT, s.slice(0, 60));
  const lineChunks = statements.filter((s) => s.startsWith('INSERT INTO trade_order_lines '));
  assert.ok(lineChunks.length > 1, `trade_order_lines in ${lineChunks.length} statement(s)`);
});

// Devil conditions 4 and 11: psql -1 wraps the file, the mount role applies it, edits survive.
test('the data file inserts with DO NOTHING, outside any explicit transaction', () => {
  const { files } = fixture();
  const statements = dataStatements(fixture().dataset);
  for (const s of statements) assert.match(s, /^INSERT INTO \w+ \([^)]+\) VALUES\n[\s\S]+\nON CONFLICT \(id\) DO NOTHING;$/);
  for (const name of ['crm.data.sql', 'crm.schema.sql']) {
    assert.doesNotMatch(files[name], /^\s*(BEGIN|COMMIT|START TRANSACTION)\b/im, name);
    assert.doesNotMatch(files[name], /DO UPDATE|CREATE EXTENSION|ALTER ROLE|CREATE ROLE|SET ROLE|GRANT /i, name);
  }
});

test('the schema is idempotent by construction', () => {
  const schema = fixture().files['crm.schema.sql'];
  assert.equal((schema.match(/CREATE TABLE (?!IF NOT EXISTS)/g) || []).length, 0);
  assert.equal((schema.match(/CREATE VIEW/g) || []).length, 0);
  assert.ok((schema.match(/CREATE OR REPLACE VIEW report_/g) || []).length >= 10);
  assert.doesNotMatch(schema, /now\(\)|CREATE TRIGGER|current_date/i);
  assert.match(schema, /CREATE TABLE IF NOT EXISTS demo_schema \(\n  file text PRIMARY KEY,\n  sha256 text NOT NULL\n\);/);
});

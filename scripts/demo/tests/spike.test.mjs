import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spikeDataset } from '../lib/spike.mjs';
import { renderFiles } from '../lib/render.mjs';
import { integrityErrors } from '../lib/graph.mjs';
import { TABLES } from '../lib/tables.mjs';
import { literal } from '../lib/sql.mjs';
import { ARGS, fixture } from './helpers.mjs';
import { buildDataset } from '../lib/dataset.mjs';

const spike = spikeDataset(fixture().dataset);
const files = renderFiles(spike);

test('seed 844 guarantees the Marc call needed by the standalone spike', () => {
  const full = buildDataset({ ...ARGS, seed: 844 });
  const selected = spikeDataset(full);
  const call = selected.interactions[0];
  assert.equal(call.kind, 'call');
  assert.equal(call.deal_id, null);
  assert.ok(selected.tables.contacts.some((c) => c.id === call.contact_id && c.email.startsWith('marc.delorme@')));
  assert.deepEqual(call, full.interactions.find((d) => d._id === call._id));
  assert.deepEqual(integrityErrors(selected).filter((e) => TABLES.some((t) => e.startsWith(`${t.name}.`))), []);
});

function tuple(table, row) {
  return `(${table.columns.map((c) => literal(row[c.name], c.type)).join(', ')})`;
}

test('the spike has a record in every table, collection and page kind', () => {
  for (const t of TABLES) assert.ok(spike.tables[t.name].length >= 1, t.name);
  assert.equal(spike.interactions.length, 1);
  assert.equal(spike.library.length, 1);
  const keys = spike.pages.map((p) => p.seed_key);
  for (const prefix of ['note-', 'decision-', 'home', 'q4-supplier-review']) assert.ok(keys.some((k) => k.startsWith(prefix)), prefix);
});

test('every spike record is identical to its full-run twin, so a later full run only adds', () => {
  const full = fixture().files;
  for (const t of TABLES) {
    for (const row of spike.tables[t.name]) assert.ok(full['crm.data.sql'].includes(tuple(t, row)), `${t.name} ${row.id}`);
  }
  for (const name of ['activity.interactions.jsonl', 'activity.library.jsonl']) {
    const lines = new Set(full[name].trim().split('\n'));
    for (const line of files[name].trim().split('\n')) assert.ok(lines.has(line), `${name} ${line.slice(0, 60)}`);
  }
  const fullPages = new Map(JSON.parse(full['pages.json']).pages.map((p) => [p.seed_key, p]));
  for (const p of JSON.parse(files['pages.json']).pages) assert.deepEqual(p, fullPages.get(p.seed_key));
});

test('the spike SQL is foreign-key closed, so it loads on its own', () => {
  const sqlErrors = integrityErrors(spike).filter((e) => TABLES.some((t) => e.startsWith(`${t.name}.`)));
  assert.deepEqual(sqlErrors, []);
});

test('the spike writes crm.data.spike.sql and no crm.data.sql', () => {
  assert.ok('crm.data.spike.sql' in files);
  assert.ok(!('crm.data.sql' in files));
  const out = mkdtempSync(join(tmpdir(), 'demo-spike-'));
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'generate.mjs');
  const run = spawnSync(process.execPath, [cli, '--anchor', ARGS.anchor, '--uid8', ARGS.uid8, '--out', out, '--spike'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.ok(readdirSync(out).includes('crm.data.spike.sql'));
  assert.ok(!readdirSync(out).includes('crm.data.sql'));
});

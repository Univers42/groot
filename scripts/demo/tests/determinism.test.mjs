import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildDataset } from '../lib/dataset.mjs';
import { renderFiles } from '../lib/render.mjs';
import { ARGS, fixture } from './helpers.mjs';

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'generate.mjs');
const FILES = ['activity.interactions.jsonl', 'activity.library.jsonl', 'crm.data.sql',
  'crm.schema.sql', 'pages.json', 'stats.json'];

test('same arguments give byte-identical files', () => {
  const again = renderFiles(buildDataset({ ...ARGS }));
  const { files } = fixture();
  assert.deepEqual(Object.keys(again).sort(), FILES);
  for (const name of FILES) assert.equal(again[name], files[name], name);
});

test('a different seed changes the data files', () => {
  const other = renderFiles(buildDataset({ ...ARGS, seed: 7 }));
  const { files } = fixture();
  for (const name of ['crm.data.sql', 'activity.interactions.jsonl', 'pages.json']) {
    assert.notEqual(other[name], files[name], name);
  }
});

function runCli(args) {
  return spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8' });
}

test('the CLI writes the six files, identical across two runs', () => {
  const dirs = [mkdtempSync(join(tmpdir(), 'demo-a-')), mkdtempSync(join(tmpdir(), 'demo-b-'))];
  for (const out of dirs) {
    const run = runCli(['--anchor', ARGS.anchor, '--seed', '42', '--uid8', ARGS.uid8, '--out', out]);
    assert.equal(run.status, 0, run.stderr);
  }
  assert.deepEqual(readdirSync(dirs[0]).sort(), FILES);
  for (const name of FILES) {
    assert.ok(readFileSync(join(dirs[0], name)).equals(readFileSync(join(dirs[1], name))), name);
  }
});

test('the CLI refuses malformed arguments', () => {
  const out = mkdtempSync(join(tmpdir(), 'demo-bad-'));
  const cases = [
    ['--anchor', '2026-13-40', '--uid8', ARGS.uid8, '--out', out],
    ['--anchor', ARGS.anchor, '--uid8', 'XYZ', '--out', out],
    ['--anchor', ARGS.anchor, '--uid8', ARGS.uid8, '--seed', 'abc', '--out', out],
    ['--anchor', ARGS.anchor, '--uid8', ARGS.uid8],
  ];
  for (const args of cases) assert.notEqual(runCli(args).status, 0, args.join(' '));
});

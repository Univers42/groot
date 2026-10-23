#!/usr/bin/env node
// Generates the Arlet demo dataset (PLAN §5.3, ADR 0005) into a directory. Zero dependencies;
// deterministic: the same arguments write byte-identical files. Writes nothing outside --out.
//
//   node scripts/demo/generate.mjs --anchor YYYY-MM-DD --uid8 <8 hex> --out <dir> [--seed 42] [--spike]
//
// --anchor is the dataset's "today" (every date is an offset back from it); --uid8 names the
// target databases demo_<uid8>_crm and demo_<uid8>_activity; --spike writes one record per table,
// collection and page kind (crm.data.spike.sql instead of crm.data.sql), each identical to its
// full-run twin, so a later full run only adds.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { buildDataset, validateArgs } from './lib/dataset.mjs';
import { spikeDataset } from './lib/spike.mjs';
import { renderFiles } from './lib/render.mjs';

function fail(message) {
  process.stderr.write(`generate: ${message}\n`);
  process.exit(2);
}

function parse(argv) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv, strict: true,
      options: {
        anchor: { type: 'string' }, seed: { type: 'string', default: '42' }, uid8: { type: 'string' },
        out: { type: 'string' }, spike: { type: 'boolean', default: false },
      },
    }).values;
  } catch (err) {
    fail(err.message);
  }
  if (!parsed.out) fail('--out <dir> is required');
  const seed = /^-?\d+$/.test(parsed.seed) ? Number(parsed.seed) : NaN;
  const args = { anchor: parsed.anchor, seed, uid8: parsed.uid8 };
  const errors = validateArgs(args);
  if (errors.length > 0) fail(errors.join('; '));
  return { args, out: parsed.out, spike: parsed.spike };
}

const { args, out, spike } = parse(process.argv.slice(2));
const full = buildDataset(args);
const files = renderFiles(spike ? spikeDataset(full) : full);
mkdirSync(out, { recursive: true });
for (const [name, content] of Object.entries(files)) writeFileSync(join(out, name), content);
const stats = JSON.parse(files['stats.json']);
process.stdout.write(`generate: ${stats.mode} dataset in ${out}: ${Object.keys(files).length} files, ` +
  `${stats.links.records} records, ${stats.links.per_record} links per record, ${stats.links.orphans.length} orphans\n`);

// Shared fixture for the generator tests: one build per test file, the arguments the seed uses.
import { buildDataset } from '../lib/dataset.mjs';
import { renderFiles } from '../lib/render.mjs';

export const ARGS = Object.freeze({ anchor: '2026-10-15', seed: 42, uid8: '0a1b2c3d' });

let cached;
export function fixture() {
  if (!cached) {
    const dataset = buildDataset(ARGS);
    cached = { dataset, files: renderFiles(dataset) };
  }
  return cached;
}

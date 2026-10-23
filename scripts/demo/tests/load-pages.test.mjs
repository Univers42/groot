import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

test('loader keeps HTTP status for JSON, empty and non-JSON error responses', () => {
  const dir = mkdtempSync(join(tmpdir(), 'load-pages-'));
  try {
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify({ users: { ines: { email: 'ines@example.test' } } }));
    writeFileSync(join(dir, 'pages.json'), '{"pages":[]}');
    for (const body of ['{"error":"unavailable"}', '', '<html>Unavailable</html>']) {
      const mock = `globalThis.fetch = async () => new Response(${JSON.stringify(body)}, {status:503});`;
      const run = spawnSync(process.execPath, [
        '--import', `data:text/javascript;base64,${Buffer.from(mock).toString('base64')}`,
        new URL('../load-pages.mjs', import.meta.url).pathname,
        '--manifest', join(dir, 'manifest.json'), '--pages', join(dir, 'pages.json'),
        '--bridge', 'http://bridge.invalid', '--utc-offset', '+0000',
      ], { encoding: 'utf8' });
      assert.equal(run.status, 1);
      assert.match(run.stderr, /cannot log in through the bridge \(HTTP 503\)/);
      if (body.startsWith('{')) assert.match(run.stderr, /unavailable/);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

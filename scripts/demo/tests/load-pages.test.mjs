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

// A bridge running OSIONOS_PAGE_STRICT_VERSION answers 409 to a content PATCH with no baseVersion
// whose content differs from the stored one. Fake: POST stores version 1, PATCH needs it.
test('loader pins its link-resolving content PATCH to the version it read (strict bridge)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'load-pages-'));
  try {
    const now = new Date();
    const offsetMinutes = (((12 * 60 + 30) - (now.getUTCHours() * 60 + now.getUTCMinutes())) % 1440 + 1440) % 1440;
    const offset = `+${String(Math.floor(offsetMinutes / 60)).padStart(2, '0')}${String(offsetMinutes % 60).padStart(2, '0')}`;
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify({
      users: { ines: { email: 'i@example.test', id: 'u1' }, jules: { email: 'j@example.test', id: 'u2' } },
      workspaces: { ops: { id: 'w1' }, finance: { id: 'w2' } },
    }));
    const mkPage = (key, text) => ({ seed_key: key, title: key, icon: 'x', workspace: 'ops', properties: [], content: [{ id: key, type: 'paragraph', content: text }] });
    writeFileSync(join(dir, 'pages.json'), JSON.stringify({ pages: [mkPage('a', 'see [[seed:b]]'), mkPage('b', 'plain')] }));
    const mock = `
      const store = new Map(); const patches = []; let n = 0;
      globalThis.fetch = async (url, init = {}) => {
        const path = new URL(url).pathname + new URL(url).search; const body = init.body ? JSON.parse(init.body) : null;
        const json = (status, data) => new Response(JSON.stringify(data), { status });
        if (path === '/api/auth/login') return json(200, { accessToken: 't' });
        if (path === '/api/profile/me') return json(200, {});
        if (path.startsWith('/api/pages?')) return json(200, []);
        if (path === '/api/people' || path.startsWith('/api/people') ) return json(200, []);
        if (init.method === 'POST' && path === '/api/pages') { const id = 'p' + (++n); store.set(id, { ...body, _id: id, contentVersion: 1 }); return json(201, { _id: id, contentVersion: 1 }); }
        if (init.method === 'PATCH') {
          const id = path.split('/').pop(); const row = store.get(id); patches.push({ id, body });
          if (body.baseVersion !== row.contentVersion) return json(409, { error: 'version conflict' });
          return json(200, { ok: true, version: row.contentVersion + 1 });
        }
        return json(200, []);
      };
      process.on('exit', () => process.stderr.write('PATCHES ' + JSON.stringify(patches) + '\\n'));`;
    writeFileSync(join(dir, 'mock.mjs'), mock);
    const run = spawnSync(process.execPath, [
      '--import', join(dir, 'mock.mjs'), new URL('../load-pages.mjs', import.meta.url).pathname,
      '--manifest', join(dir, 'manifest.json'), '--pages', join(dir, 'pages.json'),
      '--bridge', 'http://bridge.invalid', '--utc-offset', offset,
    ], { encoding: 'utf8', timeout: 60_000 });
    assert.doesNotMatch(run.stderr, /answered HTTP 409/);
    const patches = JSON.parse(/PATCHES (.*)/.exec(run.stderr)[1]);
    assert.equal(patches.length, 1);
    assert.equal(patches[0].body.baseVersion, 1);
    assert.match(patches[0].body.content[0].content, /\[\[page:p2\]\]/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

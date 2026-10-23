import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { localClock, windowReason } from '../write-window.mjs';

test('relative CLI invocation prints every minute while importing without argv stays quiet', () => {
	const cwd = fileURLToPath(new URL('../../../', import.meta.url));
	const cli = spawnSync(process.execPath, ['scripts/demo/write-window.mjs'], { cwd, encoding: 'utf8' });
	assert.equal(cli.status, 0, cli.stderr);
	assert.equal(cli.stdout.trim().split('\n').length, 1440);
	const imported = spawnSync(process.execPath, ['--input-type=module', '-e', "delete process.argv[1]; await import('./scripts/demo/write-window.mjs')"], { cwd, encoding: 'utf8' });
	assert.equal(imported.status, 0, imported.stderr);
	assert.equal(imported.stdout, '');
});

test('a closed window names its cause and when writing resumes', () => {
	assert.equal(windowReason(1, 4), "b2b-backup's hourly pg_dump; writing resumes at 01:08");
	assert.equal(windowReason(23, 59), "b2b-backup's hourly pg_dump; writing resumes at 00:08");
	assert.equal(windowReason(0, 40), 'b2b-var-gc; writing resumes at 00:51');
	assert.equal(windowReason(1, 8), '');
	assert.equal(windowReason(2, 40), '');
});

test('the clock is read at the host offset, not the container UTC', () => {
	const utc = new Date('2026-10-15T22:40:00Z');
	assert.deepEqual(localClock(utc, '+0200'), [0, 40]);
	assert.deepEqual(localClock(utc, '-0130'), [21, 10]);
	assert.throws(() => localClock(utc, undefined), /not like \+0200/);
});

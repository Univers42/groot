import assert from 'node:assert/strict';
import { test } from 'node:test';
import { localClock, windowReason } from '../write-window.mjs';

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

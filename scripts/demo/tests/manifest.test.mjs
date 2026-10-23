import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mergeState, newManifest, paramsEnv } from '../manifest.mjs';

const base = () => newManifest({ target: 'b2b', tenant: 'agency', uid8: '0a1b2c3d', anchor: '2026-10-16' });

test('workspace ids are fixed by the uid8, so a re-run never mints a second workspace', () => {
	assert.deepEqual(base().workspaces, newManifest({ target: 'x', tenant: 'y', uid8: '0a1b2c3d', anchor: '2027-01-01' }).workspaces);
	assert.notEqual(base().workspaces.operations.id, newManifest({ target: 'b2b', tenant: 'agency', uid8: 'ffffffff', anchor: '2026-10-16' }).workspaces.operations.id);
	assert.equal(base().workspaces.finance.slug, 'arlet-finance-0a1b2c3d');
});

test('params lists the tables and views, never the fingerprint table, and quotes every value', () => {
	const schema = 'CREATE TABLE IF NOT EXISTS demo_schema (x int);\nCREATE TABLE IF NOT EXISTS companies (x int);\nCREATE OR REPLACE VIEW report_top_clients AS SELECT 1;';
	const env = paramsEnv(base(), { schema, names: ['activity.library.spike.jsonl', 'activity.interactions.spike.jsonl', 'pages.json'] }, 'spike');
	assert.match(env, /^CRM_TABLES='companies,report_top_clients'$/m);
	assert.match(env, /^ACT_COLLECTIONS='interactions,library'$/m);
	assert.match(env, /^DATA_FILE='crm.data.spike.sql'$/m);
	assert.match(env, /^WS_OPS_NAME='Arlet — Operations'$/m);
	assert.doesNotMatch(env, /PASSWORD/);
});

test('the VM state fills the user and mount ids, and a state for another uid8 is refused', () => {
	const merged = mergeState(base(), 'uid8=0a1b2c3d\nmount_demo_0a1b2c3d_crm=11111111-1111-5111-8111-111111111111\nines_id=22222222-2222-4222-8222-222222222222\n');
	assert.equal(merged.mounts.demo_0a1b2c3d_crm, '11111111-1111-5111-8111-111111111111');
	assert.equal(merged.users.ines.id, '22222222-2222-4222-8222-222222222222');
	assert.throws(() => mergeState(base(), 'uid8=ffffffff\n'), /for ffffffff/);
});

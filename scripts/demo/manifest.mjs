// manifest.mjs — the per-target manifest of the Arlet demo seed (devil phase2 conditions 1, 6):
// written before anything leaves the host, ids only, git-ignored. seed-baas.sh drives it:
//
//   node scripts/demo/manifest.mjs init --file <f> --target <ssh-host> --tenant <slug>
//   node scripts/demo/manifest.mjs params --file <f> --out <bundle-dir> --only spike|full
//   node scripts/demo/manifest.mjs merge-state --file <f> --state <vm-state.txt>
//
// init keeps an existing manifest and refuses one written for another target or tenant, so a
// re-run always resumes the same uid8 rather than starting a second demo.
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { parseArgs } from 'node:util';
import { workspaceId } from './lib/uuid.mjs';

const USERS = {
	ines: { email: 'ines.caradec@arlet.example.com', name: 'Inès Caradec' },
	jules: { email: 'jules.marchand@arlet.example.com', name: 'Jules Marchand' },
};
const WORKSPACES = { operations: 'Arlet — Operations', finance: 'Arlet — Finance review' };

export function newManifest({ target, tenant, uid8, anchor }) {
	const workspaces = Object.fromEntries(
		Object.entries(WORKSPACES).map(([key, name]) => [key, { id: workspaceId(uid8, key), slug: `arlet-${key}-${uid8}`, name }]),
	);
	return { target, tenant, uid8, anchor, users: structuredClone(USERS), workspaces, mounts: {}, pages: {} };
}

export function paramsEnv(manifest, files, only) {
	const quote = (value) => `'${String(value).replace(/'/g, "'\\''")}'`;
	const schema = files.schema;
	const tables = [...schema.matchAll(/CREATE (?:TABLE IF NOT EXISTS|OR REPLACE VIEW) (\w+)/g)].map((m) => m[1]).filter((t) => t !== 'demo_schema');
	const activity = files.names.filter((name) => /^activity\..+\.jsonl$/.test(name)).sort();
	const lines = {
		UID8: manifest.uid8,
		TENANT: manifest.tenant,
		INES_EMAIL: manifest.users.ines.email,
		INES_NAME: manifest.users.ines.name,
		JULES_EMAIL: manifest.users.jules.email,
		JULES_NAME: manifest.users.jules.name,
		WS_OPS_ID: manifest.workspaces.operations.id,
		WS_OPS_SLUG: manifest.workspaces.operations.slug,
		WS_OPS_NAME: manifest.workspaces.operations.name,
		WS_FIN_ID: manifest.workspaces.finance.id,
		WS_FIN_SLUG: manifest.workspaces.finance.slug,
		WS_FIN_NAME: manifest.workspaces.finance.name,
		DATA_FILE: only === 'spike' ? 'crm.data.spike.sql' : 'crm.data.sql',
		CRM_TABLES: tables.join(','),
		ACT_COLLECTIONS: activity.map((name) => name.replace(/^activity\./, '').replace(/(\.spike)?\.jsonl$/, '')).join(','),
		ACT_FILES: activity.join(' '),
	};
	return Object.entries(lines).map(([key, value]) => `${key}=${quote(value)}`).join('\n') + '\n';
}

export function mergeState(manifest, stateText) {
	const state = Object.fromEntries(stateText.split('\n').filter((line) => line.includes('=')).map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
	if (state.uid8 && state.uid8 !== manifest.uid8) throw new Error(`the VM state is for ${state.uid8}, the manifest for ${manifest.uid8}`);
	for (const [key, value] of Object.entries(state)) {
		if (key.startsWith('mount_')) manifest.mounts[key.slice('mount_'.length)] = value;
	}
	if (state.ines_id) manifest.users.ines.id = state.ines_id;
	if (state.jules_id) manifest.users.jules.id = state.jules_id;
	return manifest;
}

function save(file, manifest) {
	mkdirSync(dirname(file), { recursive: true });
	writeFileSync(`${file}.tmp`, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
	renameSync(`${file}.tmp`, file);
}

function main() {
	const [command, ...rest] = process.argv.slice(2);
	const { values: a } = parseArgs({ args: rest, options: { file: { type: 'string' }, target: { type: 'string' }, tenant: { type: 'string' }, out: { type: 'string' }, only: { type: 'string' }, state: { type: 'string' } } });
	if (command === 'init') {
		if (existsSync(a.file)) {
			const manifest = JSON.parse(readFileSync(a.file, 'utf8'));
			if (manifest.target !== a.target || manifest.tenant !== a.tenant) throw new Error(`${a.file} is for ${manifest.target}/${manifest.tenant}, not ${a.target}/${a.tenant}`);
			return console.error(`[manifest] resuming uid8 ${manifest.uid8}`);
		}
		const manifest = newManifest({ target: a.target, tenant: a.tenant, uid8: randomBytes(4).toString('hex'), anchor: new Date().toISOString().slice(0, 10) });
		save(a.file, manifest);
		return console.error(`[manifest] new uid8 ${manifest.uid8}, anchor ${manifest.anchor}`);
	}
	const manifest = JSON.parse(readFileSync(a.file, 'utf8'));
	if (command === 'params') {
		return process.stdout.write(paramsEnv(manifest, { schema: readFileSync(`${a.out}/crm.schema.sql`, 'utf8'), names: readdirSync(a.out) }, a.only));
	}
	if (command === 'merge-state') return save(a.file, mergeState(manifest, readFileSync(a.state, 'utf8')));
	throw new Error(`unknown command ${command}`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();

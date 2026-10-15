// load-pages.mjs — writes the Arlet demo pages the way the product does: through the osionos
// bridge, logged in as Inès (ADR 0005; devil phase2 conditions 7, 9, 10, 11). It runs after
// vm-bootstrap.sh, whose state gave the manifest the user, workspace and mount ids.
//
//   node scripts/demo/load-pages.mjs --manifest <file> --pages <pages.json> --bridge <url> --utc-offset +0200
//   env: ARLET_INES_PASSWORD, ARLET_JULES_PASSWORD (scripts/tools.sh: TOOLS_PASS_ENV)
//
// Only adds: a page whose seed_key is already on the server is never posted again, and a page
// is patched only while it still holds an unresolved [[seed:]] reference, so an edit made in
// the app survives a re-run. The manifest is rewritten after every page, so a run cut short
// resumes where it stopped.
import { readFileSync, renameSync, writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { creationOrder, hasSeedReference, resolvePage, seedKeyOf } from './seed-links.mjs';
import { localClock, windowReason } from './write-window.mjs';

const { values: args } = parseArgs({ options: { manifest: { type: 'string' }, pages: { type: 'string' }, bridge: { type: 'string' }, 'utc-offset': { type: 'string' } } });
const manifest = JSON.parse(readFileSync(args.manifest, 'utf8'));
const { pages } = JSON.parse(readFileSync(args.pages, 'utf8'));
const PACE_MS = 1100;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const say = (line) => process.stderr.write(`[load-pages] ${line}\n`);

function saveManifest() {
	writeFileSync(`${args.manifest}.tmp`, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
	renameSync(`${args.manifest}.tmp`, args.manifest);
}

// The same closed windows as vm-bootstrap.sh (write-window.mjs), at the host's UTC offset.
// Caveat: this host's clock stands in for the VM's; the two are NTP-synced on this seat, but
// a drifted VM clock would let a write land on the window's edge.
async function writeWindowWait() {
	let said = '';
	for (;;) {
		const reason = windowReason(...localClock(new Date(), args['utc-offset']));
		if (!reason) return;
		if (reason !== said) say(`paused: ${reason} (not stuck; nothing to do)`);
		said = reason;
		await sleep(30_000);
	}
}

async function call(method, path, { token, body } = {}) {
	for (let attempt = 0; attempt < 6; attempt += 1) {
		const response = await fetch(`${args.bridge}${path}`, {
			method,
			headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
			body: body === undefined ? undefined : JSON.stringify(body),
		});
		if (response.status !== 429) {
			const text = await response.text();
			return { status: response.status, data: text ? JSON.parse(text) : null };
		}
		const wait = Number(response.headers.get('retry-after')) || 30;
		say(`429 on ${method} ${path}; waiting ${wait}s`);
		await sleep(wait * 1000);
	}
	throw new Error(`${method} ${path}: still rate-limited after 6 tries; stopping`);
}

async function login(email, password) {
	const { status, data } = await call('POST', '/api/auth/login', { body: { email, password } });
	if (status !== 200 || !data?.accessToken) throw new Error(`${email} cannot log in through the bridge (HTTP ${status}): ${data?.error ?? data?.message ?? ''}`);
	return data.accessToken;
}

async function optOut(token, who) {
	const { status } = await call('PATCH', '/api/profile/me', { token, body: { directoryOptOut: true } });
	if (status !== 200) throw new Error(`${who}: the directory opt-out answered HTTP ${status}`);
}

async function serverPages(token, workspaceId) {
	const { status, data } = await call('GET', `/api/pages?workspaceId=${workspaceId}`, { token });
	if (status !== 200 || !Array.isArray(data)) throw new Error(`listing workspace ${workspaceId} answered HTTP ${status}`);
	return data;
}

async function createMissing(token, existing) {
	const ids = manifest.pages;
	for (const page of creationOrder(pages)) {
		if (ids[page.seed_key]) continue;
		await writeWindowWait();
		const workspace = manifest.workspaces[page.workspace];
		const shared = page.workspace === 'finance' && page.shared_with === 'jules';
		const { status, data } = await call('POST', '/api/pages', {
			token,
			body: {
				workspaceId: workspace.id,
				parentPageId: page.parent_seed_key ? ids[page.parent_seed_key] : undefined,
				title: page.title,
				icon: page.icon,
				...resolvePage(page, ids),
				...(shared ? { collaborators: [{ userId: manifest.users.jules.id, role: 'viewer' }] } : {}),
			},
		});
		if (status !== 201) throw new Error(`creating ${page.seed_key} answered HTTP ${status}: ${data?.error ?? ''}`);
		ids[page.seed_key] = data._id;
		existing.set(page.seed_key, { ...data, content: page.content, properties: page.properties });
		saveManifest();
		await sleep(PACE_MS);
	}
}

async function resolveLinks(token, existing) {
	let patched = 0;
	for (const page of pages) {
		const stored = existing.get(page.seed_key);
		if (!stored || !hasSeedReference(stored)) continue;
		await writeWindowWait();
		const body = resolvePage(stored, manifest.pages);
		const { status } = await call('PATCH', `/api/pages/${manifest.pages[page.seed_key]}`, { token, body });
		if (status !== 200) throw new Error(`linking ${page.seed_key} answered HTTP ${status}`);
		patched += 1;
		await sleep(PACE_MS);
	}
	return patched;
}

async function verify(inesToken, julesToken) {
	const people = await call('GET', '/api/people', { token: inesToken });
	const listed = JSON.stringify(people.data ?? '');
	const directoryClean = people.status === 200 && !listed.includes(manifest.users.ines.id) && !listed.includes(manifest.users.jules.id);
	const finance = await serverPages(julesToken, manifest.workspaces.finance.id);
	const sharedOpens = finance.some((entry) => seedKeyOf(entry) === 'q4-supplier-review');
	const operations = await call('GET', `/api/pages?workspaceId=${manifest.workspaces.operations.id}`, { token: julesToken });
	return { directoryClean, sharedOpens, julesKeptOutOfOperations: operations.status === 403 };
}

async function main() {
	localClock(new Date(), args['utc-offset']);
	manifest.pages ??= {};
	const inesToken = await login(manifest.users.ines.email, process.env.ARLET_INES_PASSWORD);
	const julesToken = await login(manifest.users.jules.email, process.env.ARLET_JULES_PASSWORD);
	await writeWindowWait();
	await optOut(inesToken, 'Inès');
	await optOut(julesToken, 'Jules');
	const existing = new Map();
	for (const workspace of Object.values(manifest.workspaces)) {
		for (const entry of await serverPages(inesToken, workspace.id)) {
			const key = seedKeyOf(entry);
			if (!key) continue;
			existing.set(key, entry);
			manifest.pages[key] ??= entry._id;
		}
	}
	saveManifest();
	const before = Object.keys(manifest.pages).length;
	await createMissing(inesToken, existing);
	const patched = await resolveLinks(inesToken, existing);
	const checks = await verify(inesToken, julesToken);
	process.stdout.write(`${JSON.stringify({ created: Object.keys(manifest.pages).length - before, patched, ...checks })}\n`);
	if (!Object.values(checks).every(Boolean)) process.exitCode = 1;
}

main().catch((error) => {
	say(error.message);
	process.exitCode = 1;
});

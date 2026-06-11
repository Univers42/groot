// Deterministic tenant population (fixed PRNG seed → stable visual, testable).
import type { EngineId, IsolationId, TenantNode, TierId } from './types.ts';

export function mulberry32(seed: number): () => number {
	let a = seed >>> 0;
	return () => {
		a |= 0;
		a = (a + 0x6d2b79f5) | 0;
		let t = Math.imul(a ^ (a >>> 15), 1 | a);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

const ENGINE_COLORS: Record<EngineId, string> = {
	postgres: '#7dd3fc',
	mysql: '#fb923c',
	mongodb: '#4ade80',
	sqlite: '#a5b4fc',
	redis: '#f87171',
	cockroach: '#c084fc',
	mssql: '#f472b6',
	http: '#fde047',
};

const TIER_COLORS: Record<TierId, string> = {
	nano: '#34d399',
	basic: '#7dd3fc',
	essential: '#a78bfa',
	pro: '#fbbf24',
	max: '#f472b6',
};

const TIER_RADIUS: Record<TierId, number> = {
	nano: 2.1,
	basic: 2.7,
	essential: 3.3,
	pro: 4.1,
	max: 5.2,
};

// Realistic population: most tenants are tiny.
const TIER_COUNTS: Array<[TierId, number]> = [
	['nano', 44],
	['basic', 30],
	['essential', 22],
	['pro', 16],
	['max', 8],
];

const PRO_ENGINES: EngineId[] = ['postgres', 'mysql', 'mongodb', 'redis', 'sqlite', 'cockroach'];
const MAX_ENGINES: EngineId[] = [...PRO_ENGINES, 'mssql', 'http'];

const NAME_A = ['lumen', 'atlas', 'ferro', 'quill', 'vega', 'sable', 'koral', 'nimbus', 'tessa', 'orbit', 'pico', 'helix', 'mirek', 'cobalt', 'fable', 'astra', 'ronde', 'mosaic', 'pluma', 'verde'];
const NAME_B = ['labs', 'shop', 'kit', 'works', 'app', 'cloud', 'desk', 'flow', 'base', 'forms', 'crm', 'notes', 'pay', 'track', 'mail', 'docs', 'feed', 'cast', 'board', 'api'];

function pickEngines(tier: TierId, rand: () => number): EngineId[] {
	if (tier === 'nano') return rand() < 0.25 ? ['sqlite', 'postgres'] : ['sqlite'];
	if (tier === 'basic') return rand() < 0.5 ? ['sqlite', 'postgres'] : ['postgres'];
	if (tier === 'essential') return rand() < 0.4 ? ['postgres', 'sqlite'] : ['postgres'];
	const pool = tier === 'pro' ? PRO_ENGINES : MAX_ENGINES;
	const n = tier === 'pro' ? 2 + Math.floor(rand() * 2) : 3 + Math.floor(rand() * 2);
	const picked: EngineId[] = [];
	while (picked.length < n) {
		const e = pool[Math.floor(rand() * pool.length)] as EngineId;
		if (!picked.includes(e)) picked.push(e);
	}
	return picked;
}

function pickIsolation(rand: () => number): IsolationId {
	const v = rand();
	if (v < 0.5) return 'shared_rls';
	if (v < 0.7) return 'schema_per_tenant';
	if (v < 0.85) return 'db_per_tenant';
	return 'tenant_owned';
}

export function seedTenants(seed = 42): TenantNode[] {
	const rand = mulberry32(seed);
	const nodes: TenantNode[] = [];
	let id = 0;
	for (const [tier, count] of TIER_COUNTS) {
		for (let i = 0; i < count; i += 1) {
			const engines = pickEngines(tier, rand);
			const name = `${NAME_A[Math.floor(rand() * NAME_A.length)]}-${NAME_B[Math.floor(rand() * NAME_B.length)]}`;
			nodes.push({
				id,
				name,
				tier,
				engines,
				isolation: pickIsolation(rand),
				x: 0,
				y: 0,
				vx: 0,
				vy: 0,
				tx: 0,
				ty: 0,
				r: TIER_RADIUS[tier] * (0.88 + rand() * 0.3),
				rScale: 1,
				color: ENGINE_COLORS[engines[0] as EngineId],
				tierColor: TIER_COLORS[tier],
				phase: rand() * Math.PI * 2,
				delay: 0,
			});
			id += 1;
		}
	}
	return nodes;
}

// Pure layout functions: given the tenant population and a viewport, produce
// target positions, per-node scale and links for one narrative state. No DOM,
// no randomness beyond node fields — unit-tested with node:test.
import type { EngineId, IsolationId, LayoutResult, LayoutState, TenantNode } from './types.ts';

const TAU = Math.PI * 2;
const GOLDEN_ANGLE = 2.399963229728653;

const ENGINE_ORDER: EngineId[] = ['postgres', 'mysql', 'mongodb', 'sqlite', 'redis', 'cockroach', 'mssql', 'http'];
const TIER_ORDER = ['nano', 'basic', 'essential', 'pro', 'max'] as const;
const ISOLATION_ORDER: IsolationId[] = ['shared_rls', 'schema_per_tenant', 'db_per_tenant', 'tenant_owned'];

/** Stable pseudo-angle per node id (keeps ring placements deterministic). */
function hash01(n: number): number {
	let h = (n + 1) * 2654435761;
	h ^= h >>> 16;
	h = Math.imul(h, 0x45d9f3b);
	h ^= h >>> 16;
	return (h >>> 0) / 4294967296;
}

/** Connect each node to its nearest neighbour within the same group. */
function nearestLinks(targets: Float64Array, groups: number[]): Array<[number, number]> {
	const n = groups.length;
	const links: Array<[number, number]> = [];
	const seen = new Set<string>();
	for (let i = 0; i < n; i += 1) {
		let best = -1;
		let bestD = Infinity;
		for (let j = 0; j < n; j += 1) {
			if (i === j || groups[i] !== groups[j]) continue;
			const dx = targets[2 * i]! - targets[2 * j]!;
			const dy = targets[2 * i + 1]! - targets[2 * j + 1]!;
			const d = dx * dx + dy * dy;
			if (d < bestD) {
				bestD = d;
				best = j;
			}
		}
		if (best >= 0) {
			const key = i < best ? `${i}-${best}` : `${best}-${i}`;
			if (!seen.has(key)) {
				seen.add(key);
				links.push([i, best]);
			}
		}
	}
	return links;
}

function result(targets: Float64Array, rScales: Float64Array, links: Array<[number, number]>, scale: number): LayoutResult {
	return { targets, rScales, links, scale };
}

function base(n: number): { targets: Float64Array; rScales: Float64Array } {
	const rScales = new Float64Array(n);
	rScales.fill(1);
	return { targets: new Float64Array(n * 2), rScales };
}

function layoutNebula(nodes: TenantNode[], w: number, h: number): LayoutResult {
	const { targets, rScales } = base(nodes.length);
	const cx = w / 2;
	const cy = h / 2;
	const R = Math.min(w, h) * 0.46;
	const arms = 3;
	nodes.forEach((node, i) => {
		const t = i / nodes.length;
		const arm = i % arms;
		const angle = (arm / arms) * TAU + t * TAU * 1.9 + hash01(node.id) * 0.5;
		const radius = Math.pow(t, 0.62) * R * (0.86 + hash01(node.id * 7) * 0.32);
		targets[2 * i] = cx + Math.cos(angle) * radius * 1.18;
		targets[2 * i + 1] = cy + Math.sin(angle) * radius * 0.86;
	});
	const groups = nodes.map((_, i) => i % arms);
	return result(targets, rScales, nearestLinks(targets, groups), 1);
}

function layoutEngines(nodes: TenantNode[], w: number, h: number): LayoutResult {
	const { targets, rScales } = base(nodes.length);
	const cx = w / 2;
	const cy = h / 2;
	const ringR = Math.min(w, h) * 0.34;
	const counters = new Map<number, number>();
	const groups: number[] = [];
	nodes.forEach((node, i) => {
		const g = Math.max(0, ENGINE_ORDER.indexOf(node.engines[0] as EngineId));
		groups.push(g);
		const k = counters.get(g) ?? 0;
		counters.set(g, k + 1);
		const a = (g / ENGINE_ORDER.length) * TAU - Math.PI / 2;
		const gx = cx + Math.cos(a) * ringR * 1.25;
		const gy = cy + Math.sin(a) * ringR * 0.9;
		const r = 7 * Math.sqrt(k + 0.6);
		const theta = k * GOLDEN_ANGLE;
		targets[2 * i] = gx + Math.cos(theta) * r;
		targets[2 * i + 1] = gy + Math.sin(theta) * r;
	});
	return result(targets, rScales, nearestLinks(targets, groups), 0.85);
}

function layoutTiers(nodes: TenantNode[], w: number, h: number): LayoutResult {
	const { targets, rScales } = base(nodes.length);
	const cy = h / 2;
	const counters = new Map<number, number>();
	const groups: number[] = [];
	nodes.forEach((node, i) => {
		const g = TIER_ORDER.indexOf(node.tier);
		groups.push(g);
		const k = counters.get(g) ?? 0;
		counters.set(g, k + 1);
		const gx = w * (0.14 + g * 0.18);
		const gy = cy + Math.sin((g / TIER_ORDER.length) * Math.PI) * -h * 0.06;
		const r = 6.4 * Math.sqrt(k + 0.6);
		const theta = k * GOLDEN_ANGLE;
		targets[2 * i] = gx + Math.cos(theta) * r;
		targets[2 * i + 1] = gy + Math.sin(theta) * r;
	});
	return result(targets, rScales, nearestLinks(targets, groups), 0.8);
}

function layoutIsolation(nodes: TenantNode[], w: number, h: number): LayoutResult {
	const { targets, rScales } = base(nodes.length);
	const cx = w / 2;
	const cy = h / 2;
	const minDim = Math.min(w, h);
	const ringRadii = [0.1, 0.2, 0.3, 0.41];
	const groups: number[] = [];
	nodes.forEach((node, i) => {
		const g = ISOLATION_ORDER.indexOf(node.isolation);
		groups.push(g);
		const rr = ringRadii[g]! * minDim * 1.12;
		const angle = hash01(node.id * 13) * TAU + g * 0.4;
		const wobble = 1 + (hash01(node.id * 29) - 0.5) * 0.12;
		targets[2 * i] = cx + Math.cos(angle) * rr * wobble * 1.25;
		targets[2 * i + 1] = cy + Math.sin(angle) * rr * wobble;
	});
	return result(targets, rScales, nearestLinks(targets, groups), 0.9);
}

function layoutPlanes(nodes: TenantNode[], w: number, h: number): LayoutResult {
	const { targets, rScales } = base(nodes.length);
	// Three request streams: heavy TS orchestration, light Go control, tiny
	// Rust data plane — node size visualises per-process weight (127 vs 3.3 MiB).
	const bands = [
		{ y: 0.3, rScale: 1.75, share: 0.35 },
		{ y: 0.5, rScale: 1.0, share: 0.25 },
		{ y: 0.7, rScale: 0.5, share: 0.4 },
	];
	const groups: number[] = [];
	const counters = new Map<number, number>();
	nodes.forEach((node, i) => {
		const v = hash01(node.id * 17);
		const g = v < bands[0]!.share ? 0 : v < bands[0]!.share + bands[1]!.share ? 1 : 2;
		groups.push(g);
		const k = counters.get(g) ?? 0;
		counters.set(g, k + 1);
		const band = bands[g]!;
		targets[2 * i] = w * 0.08 + ((k * 53) % Math.max(1, Math.floor(w * 0.84)));
		targets[2 * i + 1] = h * band.y + Math.sin(k * 1.7 + g) * h * 0.045;
		rScales[i] = band.rScale;
	});
	return result(targets, rScales, nearestLinks(targets, groups), 0.9);
}

function layoutCta(nodes: TenantNode[], w: number, h: number): LayoutResult {
	const { targets, rScales } = base(nodes.length);
	const cx = w / 2;
	const cy = h / 2;
	const spacing = (Math.min(w, h) * 0.27) / Math.sqrt(nodes.length);
	nodes.forEach((_, i) => {
		const r = spacing * Math.sqrt(i + 0.6);
		const theta = i * GOLDEN_ANGLE;
		targets[2 * i] = cx + Math.cos(theta) * r;
		targets[2 * i + 1] = cy + Math.sin(theta) * r;
	});
	const groups = nodes.map(() => 0);
	return result(targets, rScales, nearestLinks(targets, groups), 0.5);
}

export function computeLayout(state: LayoutState, nodes: TenantNode[], w: number, h: number): LayoutResult {
	switch (state) {
		case 'engines':
			return layoutEngines(nodes, w, h);
		case 'tiers':
			return layoutTiers(nodes, w, h);
		case 'isolation':
			return layoutIsolation(nodes, w, h);
		case 'planes':
			return layoutPlanes(nodes, w, h);
		case 'cta':
			return layoutCta(nodes, w, h);
		case 'nebula':
		default:
			return layoutNebula(nodes, w, h);
	}
}

export const ALL_STATES: LayoutState[] = ['nebula', 'engines', 'tiers', 'isolation', 'planes', 'cta'];

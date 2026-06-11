// Shared galaxy types. Keep this file (and everything layouts.test.ts pulls
// in) erasable-TS only — the unit tests run via `node --experimental-strip-types`.
export type TierId = 'nano' | 'basic' | 'essential' | 'pro' | 'max';
export type EngineId =
	| 'postgres'
	| 'mysql'
	| 'mongodb'
	| 'sqlite'
	| 'redis'
	| 'cockroach'
	| 'mssql'
	| 'http';
export type IsolationId = 'shared_rls' | 'schema_per_tenant' | 'db_per_tenant' | 'tenant_owned';
export type LayoutState = 'nebula' | 'engines' | 'tiers' | 'isolation' | 'planes' | 'cta';

export interface TenantNode {
	id: number;
	name: string;
	tier: TierId;
	engines: EngineId[];
	isolation: IsolationId;
	/** current position (CSS px) */
	x: number;
	y: number;
	vx: number;
	vy: number;
	/** morph target */
	tx: number;
	ty: number;
	/** base radius (CSS px); layouts may scale it via rScale */
	r: number;
	rScale: number;
	color: string;
	tierColor: string;
	/** per-node drift phase */
	phase: number;
	/** morph stagger delay (ms after state change) */
	delay: number;
}

export interface LayoutResult {
	/** packed targets: [x0, y0, x1, y1, …] */
	targets: Float64Array;
	/** per-node radius scale (the "expand/shrink by context") */
	rScales: Float64Array;
	/** node-index pairs to draw as links */
	links: Array<[number, number]>;
	/** overall constellation scale, for reference/tests */
	scale: number;
}

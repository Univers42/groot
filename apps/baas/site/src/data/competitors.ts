// Competitor comparison content (sources: apps/baas/wiki/nano-edition.md §5,
// 07-commercial-viability-report.md §5). Honesty boxes are part of the brand:
// every competitor gets a genuine "choose them if" recommendation.
export interface CompareRow {
	axis: string;
	grobase: string;
	them: string;
	win: 'us' | 'them' | 'tie';
}

export interface Competitor {
	id: string;
	name: string;
	verdict: string;
	intro: string;
	rows: CompareRow[];
	honesty: string;
}

export const COMPETITORS: Competitor[] = [
	{
		id: 'supabase',
		name: 'Supabase',
		verdict: 'Supabase is excellent — if Postgres is your only engine.',
		intro:
			'Supabase pioneered the open-source Firebase alternative and its Postgres DX is superb. Grobase plays a different game: the engine is a per-mount choice, not the product\'s identity.',
		rows: [
			{ axis: 'Database engines', grobase: '8 (Postgres, MySQL, Mongo, SQLite, Redis, CockroachDB, MSSQL, HTTP)', them: '1 (PostgreSQL)', win: 'us' },
			{ axis: 'Isolation models', grobase: '4, selectable per mount (RLS → schema → db → tenant-owned)', them: 'RLS within one Postgres', win: 'us' },
			{ axis: 'Self-hosted footprint', grobase: 'From 2 MiB (Nano) to 3.1 GiB (Max) — you pick', them: 'Full docker stack (~GBs); one shape', win: 'us' },
			{ axis: 'Realtime', grobase: 'Postgres logical replication + Mongo change streams → WebSocket', them: 'Postgres realtime (mature, polished)', win: 'tie' },
			{ axis: 'Studio / dashboard UX', grobase: 'Minimal admin today', them: 'Best-in-class Studio + huge ecosystem', win: 'them' },
			{ axis: 'Pricing floor', grobase: '~$2/mo infra (Nano), < $1 idle', them: 'Free tier, then ~$25/mo Pro hosted', win: 'us' },
		],
		honesty:
			'Choose Supabase if you want a hosted Postgres with a huge community, polished Studio and years of production maturity today. Choose Grobase when the engine must be your choice — or when you\'ll need MySQL, Mongo, Redis or a customer\'s own database behind the same API tomorrow.',
	},
	{
		id: 'pocketbase',
		name: 'PocketBase',
		verdict: 'Same one-binary footprint. None of the dead end.',
		intro:
			'PocketBase made the single-file backend famous. Grobase Nano matches the shape — one static binary, embedded SQLite, ~$2/mo — and removes its ceiling: when your app outgrows SQLite, you graduate tiers instead of migrating off.',
		rows: [
			{ axis: 'Single binary, ~$2/mo', grobase: 'Yes — 5.1 MB binary, 2.0 MiB idle (measured)', them: 'Yes — 30.1 MB binary, ~12 MiB idle (measured)', win: 'us' },
			{ axis: 'SQLite implementation', grobase: 'Real C SQLite + Rust, no GC — sub-ms reads', them: 'Pure-Go SQLite (slower; TrailBase proved the gap)', win: 'us' },
			{ axis: 'Engine-agnostic', grobase: 'Same app on SQLite or external Postgres/MySQL', them: 'SQLite-only, forever', win: 'us' },
			{ axis: 'Authorization', grobase: 'ABAC + field-level masking (hide/redact per column)', them: 'Row rules only', win: 'us' },
			{ axis: 'Graph / relationship traversal', grobase: 'Obsidian-style subgraph endpoint, shipped', them: 'Not available', win: 'us' },
			{ axis: 'Multi-tenant DNA', grobase: 'Owner-stamping, scopes, capability masks built-in', them: 'Single-tenant by design', win: 'us' },
			{ axis: 'When you outgrow it', grobase: 'Graduate Nano → Basic → … → Max; same SDK, zero rewrites', them: 'Migrate to a different platform', win: 'us' },
			{ axis: 'Admin UI & JS hooks', grobase: 'Headless today (API + curl admin)', them: 'Polished embedded UI + goja JS hooks', win: 'them' },
		],
		honesty:
			'Choose PocketBase if you want the most polished single-binary experience right now — its admin UI and JS hooks are genuinely great, and TrailBase already proved the Rust+C-SQLite speed class we build on. Choose Grobase Nano when you want that footprint with cloud-grade authorization, graph queries, and a backend you will never have to migrate off.',
	},
	{
		id: 'firebase',
		name: 'Firebase',
		verdict: 'Their cloud, their data model, their bill. Or yours.',
		intro:
			'Firebase is the easiest start in mobile — and the deepest lock-in: a proprietary data model on one vendor\'s cloud, with pay-as-you-go pricing that scales with your success. Grobase is the opposite bet: open engines, your infrastructure, costs you can read.',
		rows: [
			{ axis: 'Data model', grobase: 'Open engines — SQL, documents, KV; your schema', them: 'Proprietary (Firestore document model)', win: 'us' },
			{ axis: 'Hosting', grobase: 'Self-hosted anywhere Docker runs (or one binary)', them: 'Google Cloud only', win: 'us' },
			{ axis: 'Egress / exit cost', grobase: 'It\'s your database — dump it, move it', them: 'Export is possible; re-modelling is the real cost', win: 'us' },
			{ axis: 'Pricing predictability', grobase: 'Flat infra: $2–45/mo measured per tier', them: 'Pay-as-you-go; spikes with traffic', win: 'us' },
			{ axis: 'Offline-first mobile SDKs', grobase: 'HTTP + WebSocket SDK; no offline sync layer', them: 'Mature offline sync, years ahead', win: 'them' },
			{ axis: 'Managed convenience', grobase: 'You operate it (or one binary operates itself)', them: 'Fully managed, zero ops', win: 'them' },
		],
		honesty:
			'Choose Firebase if you want zero ops and best-in-class offline mobile sync — nothing self-hosted matches that today. Choose Grobase when owning your data model, your infrastructure and a predictable bill matters more than managed convenience.',
	},
];

// Cross-cutting summary table (landing + compare page).
export const SUMMARY_AXES = [
	{ axis: 'Engines', grobase: '8', supabase: '1 (Postgres)', pocketbase: '1 (SQLite)', firebase: 'proprietary' },
	{ axis: 'Self-host floor', grobase: '5.1 MB binary, 2 MiB RAM', supabase: 'multi-GB stack', pocketbase: '30 MB binary, ~12 MiB', firebase: 'n/a (cloud only)' },
	{ axis: 'Isolation models', grobase: '4 per mount', supabase: 'RLS', pocketbase: 'single-tenant', firebase: 'security rules' },
	{ axis: 'Field-level masking', grobase: 'yes (ABAC)', supabase: 'via RLS/views', pocketbase: 'no', firebase: 'no' },
	{ axis: 'Graph endpoint', grobase: 'yes', supabase: 'no', pocketbase: 'no', firebase: 'no' },
	{ axis: 'Grow path, no rewrite', grobase: 'Nano → Max', supabase: 'vertical Postgres', pocketbase: 'migrate off', firebase: 'locked in' },
] as const;

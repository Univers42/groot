// Canvas color constants — hex mirrors of the CSS tokens in
// src/styles/abstracts/_brand-tokens.scss (canvas can't read CSS vars cheaply
// per frame; keep both files in sync when the identity changes).
export const GALAXY_COLORS = {
	bg: '#05070d',
	link: 'rgba(148, 163, 198, 0.16)',
	engines: {
		postgres: '#7dd3fc',
		mysql: '#fb923c',
		mongodb: '#4ade80',
		sqlite: '#a5b4fc',
		redis: '#f87171',
		cockroach: '#c084fc',
		mssql: '#f472b6',
		http: '#fde047',
	},
	tiers: {
		nano: '#34d399',
		basic: '#7dd3fc',
		essential: '#a78bfa',
		pro: '#fbbf24',
		max: '#f472b6',
	},
	planes: {
		ts: '#7dd3fc',
		go: '#67e8f9',
		rust: '#fb923c',
	},
} as const;

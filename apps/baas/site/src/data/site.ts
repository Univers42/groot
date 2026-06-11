// Site-wide constants. The single place that knows the product's name.
export const SITE = {
	name: 'Grobase',
	tagline: 'One backend. Every engine. Any size.',
	description:
		'Grobase is the engine-agnostic, self-hosted backend factory: auth, REST, realtime, storage, graph and edge functions over 8 database engines — from a single 5 MB binary to a multi-tenant cloud. Start on Nano, graduate to Max, never rewrite.',
	repoUrl: 'https://github.com/Univers42',
} as const;

export const NAV = [
	{ href: '/', label: 'Product' },
	{ href: '/pricing/', label: 'Pricing' },
	{ href: '/compare/', label: 'Compare' },
] as const;

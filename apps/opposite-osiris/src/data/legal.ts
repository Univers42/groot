export const POLICY_VERSION = '1.0.0';
export const POLICY_LAST_UPDATED = '2026-05-03';

export const DATA_CONTROLLER = {
	name: 'Prismatica SAS (placeholder)',
	address: '10 Rue de la Paix, 75002 Paris, France (placeholder)',
	email: 'privacy@prismatica.example',
	dpoEmail: 'dpo@prismatica.example',
} as const;

export const LEGAL_LINKS = [
	{ href: '/legal/privacy-policy/', label: 'Privacy Policy' },
	{ href: '/legal/terms/', label: 'Terms of Service' },
	{ href: '/legal/cookies/', label: 'Cookie Policy' },
	{ href: '/legal/data-rights/', label: 'Data Rights' },
] as const;

export const CONSENT_STORAGE_KEY = 'prismatica-consent-v1';
export const NEWSLETTER_INTENT_KEY = 'prismatica-newsletter-intent-v1';
export const CSRF_STORAGE_KEY = 'prismatica-csrf-token-v1';

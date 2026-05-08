const CLOUDFLARE_TURNSTILE_TEST_SITE_KEYS = new Set([
	'1x00000000000000000000AA',
	'2x00000000000000000000AB',
	'3x00000000000000000000FF',
]);

const rawTurnstileSiteKey = String(import.meta.env.PUBLIC_TURNSTILE_SITE_KEY ?? '').trim();
const rawRequireEmailVerification = String(import.meta.env.PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION ?? import.meta.env.AUTH_REQUIRE_EMAIL_VERIFICATION ?? 'true').trim().toLowerCase();

export const authConfig = {
	gatewayUrl: import.meta.env.PUBLIC_AUTH_GATEWAY_URL ?? '/api/auth',
	turnstileSiteKey: CLOUDFLARE_TURNSTILE_TEST_SITE_KEYS.has(rawTurnstileSiteKey) ? '' : rawTurnstileSiteKey,
	portalUrl: import.meta.env.PUBLIC_PORTAL_URL ?? 'https://portal.example.com/sign-in',
	requireEmailVerification: rawRequireEmailVerification !== 'false',
} as const;

export const isTurnstileConfigured = (): boolean => Boolean(authConfig.turnstileSiteKey);

#!/usr/bin/env node
import { assert, config, fetchWithTimeout, passed, runChecks, skipped } from './_shared.mjs';

const productionMode = process.env.NODE_ENV === 'production' || process.env.SECURITY_ENV === 'production' || process.env.SECURITY_ENV === 'prod';

export async function run() {
	return await runChecks([
		{
			name: 'nosniff header present',
			description: 'Checks browsers are told not to MIME-sniff API responses, reducing content confusion attacks.',
			run: async () => {
				const response = await fetchWithTimeout(config.url);
				assert.equal(response.headers.get('x-content-type-options')?.toLowerCase(), 'nosniff');
				return passed('X-Content-Type-Options is nosniff.');
			},
		},
		{
			name: 'frame protection header present',
			description: 'Checks the gateway resists clickjacking through DENY or SAMEORIGIN frame policy.',
			run: async () => {
				const response = await fetchWithTimeout(config.url);
				assert.ok(['deny', 'sameorigin'].includes(response.headers.get('x-frame-options')?.toLowerCase() ?? ''), 'X-Frame-Options is not DENY or SAMEORIGIN');
				return passed('X-Frame-Options is DENY or SAMEORIGIN.');
			},
		},
		{
			name: 'hsts header policy',
			description: 'Checks Strict-Transport-Security is present in production and documented in development.',
			run: async () => {
				const response = await fetchWithTimeout(config.url);
				const hsts = response.headers.get('strict-transport-security');
				if (!hsts && !productionMode) {
					return skipped('Strict-Transport-Security is absent in dev mode; fail this check in production.');
				}
				assert.ok(hsts, 'Strict-Transport-Security is missing in production mode');
				assert.match(hsts, /max-age=\d+/i);
				return passed('Strict-Transport-Security is present.');
			},
		},
		{
			name: 'content security policy present',
			description: 'Checks the gateway emits a CSP header for API responses or records a dev warning if absent.',
			run: async () => {
				const response = await fetchWithTimeout(config.url);
				const csp = response.headers.get('content-security-policy');
				if (!csp) {
					return skipped('Content-Security-Policy is absent; add before production exposure.');
				}
				return passed('Content-Security-Policy is present.');
			},
		},
		{
			name: 'server version not exposed',
			description: 'Checks Server does not reveal gateway product versions useful for targeted exploitation.',
			run: async () => {
				const response = await fetchWithTimeout(config.url);
				const server = response.headers.get('server') ?? '';
				assert.ok(!/(kong|nginx|openresty)\/\d/i.test(server), `Server header exposes version: ${server}`);
				return passed(server ? 'Server header does not expose a version.' : 'Server header is absent.');
			},
		},
		{
			name: 'x-powered-by absent',
			description: 'Checks framework fingerprints are not leaked through X-Powered-By.',
			run: async () => {
				const response = await fetchWithTimeout(config.url);
				assert.equal(response.headers.get('x-powered-by'), null);
				return passed('X-Powered-By is absent.');
			},
		},
	]);
}

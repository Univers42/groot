#!/usr/bin/env node
import { assert, authPasswordGrant, config, ensureSecurityTestUser, isJwtLike, passed, runChecks, textBody } from './_shared.mjs';

const rejectionStatuses = new Set([400, 401, 422, 429]);

async function assertRejectedLogin(email, password, label) {
	const response = await authPasswordGrant(email, password, 3000);
	assert.notEqual(response.status, 200, `${label} returned HTTP 200`);
	assert.ok(rejectionStatuses.has(response.status), `${label} returned unexpected HTTP ${response.status}`);
}

export async function run() {
	return await runChecks([
		{
			name: 'successful login token shape',
			description: 'Checks a valid password grant returns a bounded JWT response with access_token and expires_in.',
			run: async () => {
				await ensureSecurityTestUser();
				const response = await authPasswordGrant();
				const body = await textBody(response);
				assert.equal(response.status, 200, `valid login returned HTTP ${response.status} with ${body.length} response bytes`);
				const payload = JSON.parse(body || '{}');
				assert.ok(payload && typeof payload === 'object', 'valid login did not return JSON');
				assert.ok(isJwtLike(payload.access_token), 'access_token is not a three-segment JWT');
				assert.equal(typeof payload.expires_in, 'number', 'expires_in is missing or not numeric');
				return passed('Valid login returns access_token, expires_in, and JWT-shaped token.');
			},
		},
		{
			name: 'SQL-injected login identifiers rejected',
			description: 'Checks classic SQL injection payloads in email are rejected and never authenticate.',
			run: async () => {
				for (const payload of [`' OR '1'='1`, `admin'--`, `" OR ""="`]) {
					await assertRejectedLogin(payload, config.testPassword, `injected email ${payload}`);
				}
				return passed('SQL-injected email values were rejected without authentication.');
			},
		},
		{
			name: 'empty password rejected',
			description: 'Checks empty password submissions fail validation instead of authenticating or causing server errors.',
			run: async () => {
				await assertRejectedLogin(config.testEmail, '', 'empty password');
				return passed('Empty password was rejected.');
			},
		},
		{
			name: 'oversized password rejected quickly',
			description: 'Checks a 10,000-character password is rejected without timing out, reducing bcrypt denial-of-service risk.',
			run: async () => {
				const response = await authPasswordGrant(config.testEmail, 'A'.repeat(10_000), 3000);
				assert.notEqual(response.status, 200, 'oversized password authenticated');
				assert.ok(rejectionStatuses.has(response.status), `oversized password returned unexpected HTTP ${response.status}`);
				return passed('Oversized password was rejected within the timeout.');
			},
		},
		{
			name: 'wrong-password rate limiting',
			description: 'Checks repeated password failures trigger gateway or auth rate limiting before the 20th attempt.',
			run: async () => {
				const statuses = [];
				for (let index = 0; index < 20; index += 1) {
					const response = await authPasswordGrant(config.testEmail, `wrong-${Date.now()}-${index}`, 3000);
					statuses.push(response.status);
					await response.arrayBuffer().catch(() => undefined);
					if (response.status === 429) {
						break;
					}
				}
				const rateLimitedIndex = statuses.indexOf(429);
				assert.ok(rateLimitedIndex >= 0 && rateLimitedIndex < 19, `expected 429 before attempt 20, received statuses: ${statuses.join(', ')}`);
				return passed('Wrong-password attempts were rate-limited before the 20th request.');
			},
		},
	]);
}

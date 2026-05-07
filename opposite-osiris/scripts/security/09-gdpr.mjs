#!/usr/bin/env node
import { assert, authPasswordGrant, baasHeaders, config, ensureSecurityTestUser, fetchWithTimeout, isJwtLike, jsonBody, passed, restUrl, runChecks, textBody } from './_shared.mjs';

async function expectAnonForbidden(path, label) {
	const response = await fetchWithTimeout(restUrl(path), { headers: baasHeaders() });
	if (response.ok) {
		const body = await jsonBody(response);
		assert.ok(Array.isArray(body) && body.length === 0, `${label} returned data to anon role`);
	} else {
		assert.ok([400, 401, 403, 404, 406].includes(response.status), `${label} returned unexpected HTTP ${response.status}`);
	}
}

async function loginToken(email = config.testEmail, password = config.testPassword) {
	await ensureSecurityTestUser();
	const response = await authPasswordGrant(email, password);
	assert.equal(response.status, 200, `login failed with HTTP ${response.status}`);
	const payload = await jsonBody(response);
	assert.ok(isJwtLike(payload?.access_token), 'login did not return a JWT access token');
	return payload.access_token;
}

export async function run() {
	return await runChecks([
		{
			name: 'anon cannot read consents',
			description: 'Checks consent audit records are private and unavailable to anonymous callers.',
			run: async () => {
				await expectAnonForbidden('/user_consents?select=*', 'user_consents');
				return passed('Anonymous role cannot read user_consents.');
			},
		},
		{
			name: 'anon cannot read activity logs',
			description: 'Checks IP/device-bearing activity logs are private under GDPR and CNIL guidance.',
			run: async () => {
				await expectAnonForbidden('/user_activities?select=*', 'user_activities');
				return passed('Anonymous role cannot read user_activities.');
			},
		},
		{
			name: 'anon cannot read password hashes',
			description: 'Checks anonymous callers cannot select password_hash from users.',
			run: async () => {
				await expectAnonForbidden('/users?select=password_hash', 'users.password_hash');
				return passed('Anonymous role cannot read users.password_hash.');
			},
		},
		{
			name: 'export RPC requires JWT',
			description: 'Checks gdpr_export_my_data rejects unauthenticated calls.',
			run: async () => {
				const response = await fetchWithTimeout(restUrl('/rpc/gdpr_export_my_data'), { method: 'POST' });
				assert.ok([401, 403].includes(response.status), `export RPC without JWT returned HTTP ${response.status}`);
				return passed('gdpr_export_my_data requires authentication.');
			},
		},
		{
			name: 'deletion RPC requires JWT',
			description: 'Checks gdpr_request_deletion rejects unauthenticated calls.',
			run: async () => {
				const response = await fetchWithTimeout(restUrl('/rpc/gdpr_request_deletion'), { method: 'POST' });
				assert.ok([401, 403].includes(response.status), `deletion RPC without JWT returned HTTP ${response.status}`);
				return passed('gdpr_request_deletion requires authentication.');
			},
		},
		{
			name: 'export is scoped to current user',
			description: 'Checks a user JWT export does not include another user email or records.',
			run: async () => {
				const token = await loginToken();
				const response = await fetchWithTimeout(restUrl('/rpc/gdpr_export_my_data'), {
					method: 'POST',
					headers: baasHeaders({ Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }),
					body: '{}',
				});
				if (response.status !== 200) {
					throw new Error(`export returned HTTP ${response.status}: ${await textBody(response)}`);
				}
				const payload = await jsonBody(response);
				const serialized = JSON.stringify(payload);
				assert.ok(serialized.includes(config.testEmail), 'export does not include the current user email');
				assert.ok(!serialized.includes('jane.doe@example.com'), 'export leaked another seeded user email');
				return passed('GDPR export is scoped to the authenticated user.');
			},
		},
	]);
}

#!/usr/bin/env node
import { assert, authPasswordGrant, baasHeaders, fetchWithTimeout, noInternalLeak, passed, restUrl, runChecks, textBody } from './_shared.mjs';

async function assertPrivateTable(path, label) {
	const response = await fetchWithTimeout(restUrl(path), { headers: baasHeaders() });
	const body = await textBody(response);
	assert.ok(noInternalLeak(body), `${label} leaked internals: ${body.slice(0, 240)}`);
	assert.ok([401, 403, 404].includes(response.status), `${label} is accessible with HTTP ${response.status}`);
}

export async function run() {
	return await runChecks([
		{
			name: 'password hashes not exposed',
			description: 'Checks anonymous users cannot select password_hash from the users table.',
			run: async () => {
				const response = await fetchWithTimeout(restUrl('/users?select=password_hash'), { headers: baasHeaders() });
				const body = await textBody(response);
				assert.ok(noInternalLeak(body), `password_hash response leaked internals: ${body.slice(0, 240)}`);
				if (response.ok) {
					const parsed = JSON.parse(body || '[]');
					assert.ok(Array.isArray(parsed) && parsed.length === 0, 'password_hash returned rows');
				} else {
					assert.ok([400, 401, 403, 404, 406].includes(response.status), `unexpected password_hash HTTP ${response.status}`);
				}
				return passed('password_hash is unavailable to anonymous REST callers.');
			},
		},
		{
			name: 'auth errors do not leak internals',
			description: 'Checks failed auth responses omit stack traces, file paths, and database details.',
			run: async () => {
				const response = await authPasswordGrant('not-a-user@example.invalid', 'wrong-password');
				assert.notEqual(response.status, 200, 'invalid auth request succeeded');
				const body = await textBody(response);
				assert.ok(noInternalLeak(body), `auth error leaked internals: ${body.slice(0, 240)}`);
				return passed('Auth error response did not expose internals.');
			},
		},
		{
			name: 'sessions table private',
			description: 'Checks anonymous users cannot read session tokens through PostgREST.',
			run: async () => {
				await assertPrivateTable('/sessions', 'sessions table');
				return passed('sessions table is not accessible to anonymous users.');
			},
		},
		{
			name: 'user_tokens table private',
			description: 'Checks anonymous users cannot read verification or reset tokens through PostgREST.',
			run: async () => {
				await assertPrivateTable('/user_tokens', 'user_tokens table');
				return passed('user_tokens table is not accessible to anonymous users.');
			},
		},
		{
			name: 'PostgREST root hides private tables',
			description: 'Checks the OpenAPI root does not advertise private token/session tables.',
			run: async () => {
				const response = await fetchWithTimeout(restUrl('/'), { headers: baasHeaders() });
				assert.ok(response.ok, `PostgREST root returned HTTP ${response.status}`);
				const body = await textBody(response);
				assert.ok(!/\b(user_tokens|sessions)\b/.test(body), 'PostgREST root exposes private table names');
				return passed('PostgREST root does not list private tables.');
			},
		},
	]);
}

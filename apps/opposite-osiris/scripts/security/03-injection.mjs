#!/usr/bin/env node
import { assert, baasHeaders, fetchWithTimeout, jsonBody, noInternalLeak, passed, restUrl, runChecks, safePublicColumns, textBody } from './_shared.mjs';

async function assertSafeQuery(path, label) {
	const response = await fetchWithTimeout(restUrl(path), { headers: baasHeaders() });
	const body = await textBody(response);
	assert.notEqual(response.status, 500, `${label} returned HTTP 500`);
	assert.ok(noInternalLeak(body), `${label} leaked internal error details: ${body.slice(0, 240)}`);

	if (response.ok) {
		const parsed = JSON.parse(body || '[]');
		const rows = Array.isArray(parsed) ? parsed : [parsed];
		for (const row of rows) {
			assert.ok(safePublicColumns(row), `${label} returned non-public columns: ${Object.keys(row ?? {}).join(', ')}`);
		}
	} else {
		assert.ok([400, 401, 403, 404, 406].includes(response.status), `${label} returned unexpected HTTP ${response.status}`);
	}
}

export async function run() {
	return await runChecks([
		{
			name: 'select parameter SQL injection blocked',
			description: 'Checks injected statements in PostgREST select do not execute or leak database details.',
			run: async () => {
				await assertSafeQuery('/users?select=*;DROP TABLE users;--', 'select injection');
				return passed('Injected select parameter was safely rejected or constrained.');
			},
		},
		{
			name: 'eq filter SQL injection blocked',
			description: 'Checks injected equality filters do not bypass PostgREST query parsing or leak internals.',
			run: async () => {
				const injectedFilter = encodeURIComponent("' OR 1=1--");
				await assertSafeQuery(`/users?email=eq.${injectedFilter}`, 'eq injection');
				return passed('Injected eq filter was safely rejected or constrained.');
			},
		},
		{
			name: 'order parameter SQL injection blocked',
			description: 'Checks injected order clauses do not execute stacked SQL statements.',
			run: async () => {
				await assertSafeQuery('/users?order=email;DROP TABLE sessions', 'order injection');
				return passed('Injected order parameter was safely rejected or constrained.');
			},
		},
		{
			name: 'password_hash column unavailable',
			description: 'Checks anonymous REST callers cannot directly select password hashes.',
			run: async () => {
				const response = await fetchWithTimeout(restUrl('/users?select=password_hash'), { headers: baasHeaders() });
				const body = await textBody(response);
				assert.ok(noInternalLeak(body), `password_hash query leaked internals: ${body.slice(0, 240)}`);
				if (response.ok) {
					const parsed = await jsonBody(response);
					assert.ok(Array.isArray(parsed) && parsed.length === 0, 'password_hash query returned rows');
				} else {
					assert.ok([400, 401, 403, 404, 406].includes(response.status), `password_hash query returned unexpected HTTP ${response.status}`);
				}
				return passed('password_hash is not readable through anonymous PostgREST.');
			},
		},
	]);
}

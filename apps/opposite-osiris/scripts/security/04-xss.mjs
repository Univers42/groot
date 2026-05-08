#!/usr/bin/env node
import { randomUUID } from 'node:crypto';
import { assert, baasHeaders, fetchWithTimeout, isJsonResponse, jsonBody, passed, restUrl, runChecks } from './_shared.mjs';

const payloads = [
	'<script>alert(1)</script>',
	'"><img src=x onerror=alert(1)>',
	'javascript:alert(1)',
	'<svg onload=alert(1)>',
];

export async function run() {
	return await runChecks([
		{
			name: 'REST endpoints return JSON only',
			description: 'Checks REST responses use application/json rather than text/html, reducing reflected XSS surface.',
			run: async () => {
				const response = await fetchWithTimeout(restUrl('/users?select=id,username,email&limit=1'), { headers: baasHeaders() });
				assert.ok(response.ok, `users query returned HTTP ${response.status}`);
				assert.ok(isJsonResponse(response), `REST endpoint returned ${response.headers.get('content-type')}`);
				return passed('REST users endpoint returned application/json.');
			},
		},
		{
			name: 'profile XSS payload writes rejected or literal',
			description: 'Checks stored profile fields reject script payloads or store them as inert JSON strings for frontend escaping.',
			run: async () => {
				for (const payload of payloads) {
					const response = await fetchWithTimeout(restUrl('/users?select=id,username,bio'), {
						method: 'POST',
						headers: baasHeaders({ 'Content-Type': 'application/json', Prefer: 'return=representation' }),
						body: JSON.stringify({
							username: payload,
							email: `xss-${randomUUID()}@example.invalid`,
							bio: payload,
						}),
					}, 4000);

					if (!response.ok) {
						assert.ok([400, 401, 403, 405, 409, 422].includes(response.status), `XSS write returned unexpected HTTP ${response.status}`);
						continue;
					}

					assert.ok(isJsonResponse(response), `XSS write returned ${response.headers.get('content-type')}`);
					const rows = await jsonBody(response);
					const row = Array.isArray(rows) ? rows[0] : rows;
					assert.equal(row.username, payload, 'username payload was transformed unpredictably');
					assert.equal(row.bio, payload, 'bio payload was transformed unpredictably');
				}

				return passed('XSS payloads were rejected or returned as literal JSON strings.');
			},
		},
	]);
}

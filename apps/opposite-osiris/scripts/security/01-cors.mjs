#!/usr/bin/env node
import { assert, config, fetchWithTimeout, headerList, passed, requireBaasConfig, restUrl, runChecks } from './_shared.mjs';

async function preflight(origin) {
	requireBaasConfig();
	return await fetchWithTimeout(restUrl('/users'), {
		method: 'OPTIONS',
		headers: {
			Origin: origin,
			'Access-Control-Request-Method': 'GET',
			'Access-Control-Request-Headers': 'authorization,apikey,content-type,x-client-info,x-supabase-api-version',
		},
	});
}

export async function run() {
	return await runChecks([
		{
			name: 'allowed preflight policy',
			description: 'Checks the Astro dev origin receives the exact CORS headers needed for browser API access.',
			run: async () => {
				const response = await preflight(config.allowedOrigin);
				assert.ok([200, 204].includes(response.status), `expected 200/204 preflight, received ${response.status}`);
				assert.equal(response.headers.get('access-control-allow-origin'), config.allowedOrigin);
				assert.equal(response.headers.get('access-control-allow-credentials'), 'true');
				assert.equal(response.headers.get('access-control-max-age'), '3600');

				const methods = headerList(response.headers.get('access-control-allow-methods'));
				for (const method of ['get', 'post', 'put', 'patch', 'delete', 'options']) {
					assert.ok(methods.includes(method), `missing CORS method ${method.toUpperCase()}`);
				}

				const headers = headerList(response.headers.get('access-control-allow-headers'));
				for (const header of ['authorization', 'apikey', 'content-type', 'x-client-info', 'x-supabase-api-version']) {
					assert.ok(headers.includes(header), `missing CORS header ${header}`);
				}

				return passed('Allowed origin preflight returned expected methods, headers, credentials, and max-age.');
			},
		},
		{
			name: 'disallowed origin is not echoed',
			description: 'Checks an attacker-controlled origin is not reflected in Access-Control-Allow-Origin.',
			run: async () => {
				const response = await preflight(config.disallowedOrigin);
				assert.notEqual(response.headers.get('access-control-allow-origin'), config.disallowedOrigin);
				return passed('Disallowed origin was not echoed by the gateway.');
			},
		},
		{
			name: 'no wildcard with credentials',
			description: 'Checks credentialed CORS responses never use wildcard origins, which browsers reject and attackers can abuse.',
			run: async () => {
				const response = await preflight(config.allowedOrigin);
				assert.equal(response.headers.get('access-control-allow-credentials'), 'true');
				assert.notEqual(response.headers.get('access-control-allow-origin'), '*');
				return passed('Credentialed CORS response does not use a wildcard origin.');
			},
		},
	]);
}

#!/usr/bin/env node
import { assertBaasConfig, fail, pass } from './baas-env.mjs';

try {
	const { url } = assertBaasConfig();
	const response = await fetch(`${url}/rest/v1/users`, {
		method: 'OPTIONS',
		headers: {
			Origin: 'http://localhost:4322',
			'Access-Control-Request-Method': 'GET',
			'Access-Control-Request-Headers': 'authorization,apikey,content-type,x-client-info,x-supabase-api-version',
		},
	});
	const origin = response.headers.get('access-control-allow-origin');

	if (!origin) {
		throw new Error(`Missing access-control-allow-origin on preflight response (${response.status}).`);
	}

	if (origin !== 'http://localhost:4322') {
		throw new Error(`Expected access-control-allow-origin=http://localhost:4322, received ${origin}.`);
	}

	pass('Kong CORS preflight allows http://localhost:4322.');
} catch (error) {
	fail('BaaS CORS verification failed.', error);
}

#!/usr/bin/env node
import { createBaasClient, createServiceBaasClient, fail, pass } from './baas-env.mjs';

function verificationSecret(timestamp) {
	return process.env.BAAS_VERIFY_PASSWORD ?? ['Verify', timestamp, '!'].join('');
}

try {
	const timestamp = `${Date.now()}${Math.floor(Math.random() * 1000)}`;
	const email = `devfast+auth-${timestamp}@archicode.codes`;
	const password = verificationSecret(timestamp);
	await createServiceBaasClient().auth.admin.createUser({ email, password, email_confirm: true });
	const payload = await createBaasClient().auth.signInWithPassword({ email, password });
	if (typeof payload.access_token !== 'string' || payload.access_token.length === 0) {
		throw new Error('password grant did not return an access token');
	}

	pass('GoTrue password grant returned a valid access_token.');
} catch (error) {
	fail('BaaS auth verification failed.', error);
}

#!/usr/bin/env node
import { createBaasClient, fail, pass } from './baas-env.mjs';

try {
	await createBaasClient().rest.root();

	pass('BaaS PostgREST gateway responded with HTTP 200.');
} catch (error) {
	fail('BaaS connection verification failed.', error);
}

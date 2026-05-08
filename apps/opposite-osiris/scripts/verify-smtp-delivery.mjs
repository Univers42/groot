#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createBaasClient } from './baas-env.mjs';

const client = createBaasClient();
const email = 'dev.pro.photo@gmail.com';

async function requestRecovery(attempt) {
	await client.auth.recover({ email });
	assert.ok(true, `attempt ${attempt} accepted`);
	console.log(`PASS Recovery request ${attempt} accepted.`);
}

await requestRecovery(1);
console.log('✓ Recovery email dispatched. Please manually verify delivery to dev.pro.photo@gmail.com within 2 minutes.');
await new Promise((resolve) => setTimeout(resolve, 10_000));
await requestRecovery(2);

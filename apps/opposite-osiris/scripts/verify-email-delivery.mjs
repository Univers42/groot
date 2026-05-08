#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createBaasClient } from './baas-env.mjs';

const recoveryEmail = process.env.EMAIL_DELIVERY_TEST_ADDRESS ?? 'john.doe@example.com';

try {
	await createBaasClient().auth.recover({ email: recoveryEmail });
	assert.ok(true, 'GoTrue accepted recovery request through SDK.');
	console.log(`PASS GoTrue accepted a password recovery email request for ${recoveryEmail}.`);
	console.log('Manual delivery check required: verify the SMTP test inbox dev.pro.photo@gmail.com and the target recovery inbox according to the test account routing.');
} catch (error) {
	console.error(error instanceof Error ? error.message : String(error));
	process.exitCode = 1;
}

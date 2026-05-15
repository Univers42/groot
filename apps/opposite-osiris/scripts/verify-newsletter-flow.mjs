#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createBaasClient, createServiceBaasClient } from './baas-env.mjs';
import { uniqueTestEmail } from './test-email.mjs';

const client = createBaasClient();
const serviceClient = createServiceBaasClient();
const testEmail = uniqueTestEmail('newsletter', 'NEWSLETTER_VERIFY_EMAIL');
const testPassword = 'Test123!';

const steps = [];

function record(name, ok, detail = '') {
	steps.push({ Step: name, Result: ok ? 'PASS' : 'FAIL', Detail: detail });
}

function errorMessage(error) {
	return error instanceof Error ? error.message : String(error);
}

async function runStep(name, action, detailText = String) {
	try {
		const detail = await action();
		record(name, true, detailText(detail));
		return detail;
	} catch (error) {
		record(name, false, errorMessage(error));
		return '';
	}
}

async function authenticateTestUser() {
	await serviceClient.auth.admin.createUser({ email: testEmail, password: testPassword, email_confirm: true });
	await serviceClient.from('users').insert({
		username: testEmail.split('@')[0].replaceAll(/[^a-z0-9_-]/gi, '-'),
		email: testEmail,
		password_hash: ['managed', 'by', 'gotrue'].join('-'),
		theme: 'light',
		notifications_enabled: true,
		is_email_verified: true,
	});
	const payload = await client.auth.signInWithPassword({ email: testEmail, password: testPassword });
	assert.equal(typeof payload.access_token, 'string');
	return payload.access_token;
}

async function assertRpcOk(name, body, token) {
	const result = await createBaasClient(token).rpc(name, body);
	return JSON.stringify(result ?? {});
}

async function main() {
	const token = await runStep('Authenticate test user', authenticateTestUser, () => 'JWT returned');

	if (token) {
		await runStep('Grant newsletter consent', async () => {
			await assertRpcOk('gdpr_set_newsletter', { granted: true }, token);
			return 'HTTP 200';
		});
		await runStep('Grant newsletter idempotently', async () => {
			await assertRpcOk('gdpr_set_newsletter', { granted: true }, token);
			return 'HTTP 200';
		});
		await runStep('Withdraw newsletter consent', async () => {
			await assertRpcOk('gdpr_withdraw_consent', { consent_type: 'newsletter' }, token);
			return 'HTTP 200';
		});
		await runStep('Export data includes withdrawal', async () => {
			const body = await assertRpcOk('gdpr_export_my_data', {}, token);
			assert.match(body, /newsletter/i);
			assert.match(body, /withdrawn_at/i);
			return 'newsletter withdrawn_at found';
		});
	}

	console.table(steps);
	if (steps.some((step) => step.Result === 'FAIL')) {
		process.exitCode = 1;
	}
}

await main();

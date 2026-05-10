import { existsSync, readFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { resolve } from 'node:path';

for (const file of ['.env.local', '.env', '../../.env.local', '../../apps/baas/.env.local']) {
	const path = resolve(process.cwd(), file);
	if (!existsSync(path)) continue;
	for (const rawLine of readFileSync(path, 'utf8').split(/\r?\n/)) {
		const line = rawLine.trim();
		if (!line || line.startsWith('#') || !line.includes('=')) continue;
		const [key, ...valueParts] = line.split('=');
		let value = valueParts.join('=').trim();
		if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
		if (key && process.env[key] === undefined) process.env[key] = value;
	}
}

const gatewayBaseUrl = (process.env.AUTH_GATEWAY_TEST_URL ?? `http://localhost:${process.env.AUTH_GATEWAY_PORT ?? 8787}/api/auth`).replace(/\/$/, '');
const timestamp = `${Date.now()}${Math.floor(Math.random() * 1000)}`;
const testPassword = process.env.BAAS_VERIFY_PASSWORD ?? ['Verify', timestamp, '!'].join('');
const testIdentity = {
	email: `devfast+verify-${timestamp}@archicode.codes`,
	username: `verify_${Number(timestamp).toString(36)}`.slice(0, 32),
};

function safeMessage(message) {
	return String(message).replaceAll(/[\r\n\t]/g, ' ').slice(0, 240);
}

function logPass(message) {
	console.log(`PASS ${safeMessage(message)}`);
}

function fail(message, detail = '') {
	const safeDetail = detail ? ` ${safeMessage(detail)}` : '';
	console.error(`FAIL ${safeMessage(message)}${safeDetail}`);
	process.exit(1);
}

function requestJson(method, path, body) {
	const url = new URL(`${gatewayBaseUrl}${path}`);
	const transport = url.protocol === 'https:' ? https : http;
	const payload = body === undefined ? undefined : JSON.stringify(body);
	return new Promise((resolveRequest, rejectRequest) => {
		const request = transport.request(url, {
			method,
			rejectUnauthorized: false,
			timeout: 15_000,
			headers: {
				Accept: 'application/json',
				...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}),
			},
		}, (response) => {
			let text = '';
			response.setEncoding('utf8');
			response.on('data', (chunk) => { text += chunk; });
			response.on('end', () => {
				let json = {};
				try { json = text ? JSON.parse(text) : {}; } catch { json = { message: text }; }
				resolveRequest({ status: response.statusCode ?? 0, json });
			});
		});
		request.on('timeout', () => request.destroy(new Error('request timed out')));
		request.on('error', rejectRequest);
		if (payload) request.write(payload);
		request.end();
	});
}

function registrationBody(identity) {
	return {
		email: identity.email,
		password: testPassword,
		turnstileToken: 'localhost-turnstile-token',
		profile: {
			username: identity.username,
			confirmPassword: testPassword,
			emailVerificationConsent: false,
			notificationsEnabled: true,
		},
	};
}

const seededAvailabilityPath = `/availability?email=${encodeURIComponent('john.doe@example.com')}&username=${encodeURIComponent('johndoe')}`;
const seeded = await requestJson('GET', seededAvailabilityPath);
if (seeded.status !== 200 || seeded.json.email?.available !== false || seeded.json.username?.available !== false) {
	fail('Seeded username/email should be reported as unavailable.', JSON.stringify({ status: seeded.status, body: seeded.json }));
}
logPass('Seeded username and email are detected as unavailable.');

const uniqueAvailabilityPath = `/availability?email=${encodeURIComponent(testIdentity.email)}&username=${encodeURIComponent(testIdentity.username)}`;
const unique = await requestJson('GET', uniqueAvailabilityPath);
if (unique.status !== 200 || unique.json.email?.available !== true || unique.json.username?.available !== true) {
	fail('Unique username/email should be reported as available.', JSON.stringify({ status: unique.status, body: unique.json }));
}
logPass('Unique username and email are detected as available.');

const created = await requestJson('POST', '/register', registrationBody(testIdentity));
if (created.status !== 200) {
	fail('Registration should create a local confirmed account.', JSON.stringify({ status: created.status, body: created.json }));
}
logPass('Registration endpoint created a new local account.');

const duplicate = await requestJson('POST', '/register', registrationBody(testIdentity));
if (duplicate.status !== 409) {
	fail('Duplicate registration should be rejected with HTTP 409.', JSON.stringify({ status: duplicate.status, body: duplicate.json }));
}
logPass('Duplicate username/email registration is rejected with HTTP 409.');

const login = await requestJson('POST', '/login', {
	email: testIdentity.email,
	password: testPassword,
	turnstileToken: 'localhost-turnstile-token',
});
if (login.status !== 200 || typeof login.json.access_token !== 'string') {
	fail('Newly registered account should be able to sign in.', JSON.stringify({ status: login.status, body: login.json }));
}
logPass('Newly registered account can sign in through the auth gateway.');

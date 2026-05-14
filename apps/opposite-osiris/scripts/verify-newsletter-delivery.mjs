#!/usr/bin/env node
import http from 'node:http';
import https from 'node:https';

const gatewayBaseUrl = (process.env.AUTH_GATEWAY_TEST_URL ?? `http://127.0.0.1:${process.env.AUTH_GATEWAY_PORT ?? 8787}`).replace(/\/$/, '');
const mailpitApiUrl = (process.env.MAILPIT_API_URL ?? 'http://mailpit:8025').replace(/\/$/, '');
const verifyMailpit = process.env.MAILPIT_VERIFY_DELIVERY !== 'false';
const email = `devfast+newsletter-healthcheck-${Date.now()}@archicode.codes`;

function safeMessage(message) {
	return String(message).replaceAll(/[\r\n\t]/g, ' ').slice(0, 240);
}

function requestJson(method, url, body) {
	const parsed = new URL(url);
	const transport = parsed.protocol === 'https:' ? https : http;
	const payload = body === undefined ? undefined : JSON.stringify(body);
	return new Promise((resolveRequest, rejectRequest) => {
		const request = transport.request(parsed, {
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

async function delay(ms) {
	await new Promise((resolveDelay) => setTimeout(resolveDelay, ms));
}

function messageMatchesEmail(message) {
	return JSON.stringify(message).toLowerCase().includes(email.toLowerCase());
}

async function waitForMailpitMessage() {
	for (let attempt = 0; attempt < 20; attempt += 1) {
		const response = await requestJson('GET', `${mailpitApiUrl}/api/v1/messages?limit=50`);
		if (response.status >= 200 && response.status < 300) {
			let messages = [];
			if (Array.isArray(response.json?.messages)) messages = response.json.messages;
			else if (Array.isArray(response.json)) messages = response.json;
			if (messages.some(messageMatchesEmail)) return true;
		}
		await delay(500);
	}
	return false;
}

function fail(message, detail = '') {
	const suffix = detail ? ` ${safeMessage(detail)}` : '';
	console.error(`FAIL ${safeMessage(message)}${suffix}`);
	process.exit(1);
}

const subscription = await requestJson('POST', `${gatewayBaseUrl}/api/newsletter/subscribe`, { email });
if (subscription.status !== 200) {
	fail('Newsletter subscription endpoint did not accept the healthcheck request.', JSON.stringify({ status: subscription.status, body: subscription.json }));
}

if (verifyMailpit && !await waitForMailpitMessage()) {
	fail('Newsletter confirmation was accepted but no message appeared in Mailpit.', email);
}

console.log(`PASS Newsletter confirmation accepted${verifyMailpit ? ' and captured by Mailpit' : ''}.`);

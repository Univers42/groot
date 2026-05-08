import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const envFiles = ['.env.local', '.env'];
for (const file of envFiles) {
	const path = resolve(process.cwd(), file);
	if (!existsSync(path)) {
		continue;
	}

	for (const rawLine of readFileSync(path, 'utf8').split(/\r?\n/)) {
		const line = rawLine.trim();
		if (!line || line.startsWith('#') || !line.includes('=')) {
			continue;
		}
		const [key, ...valueParts] = line.split('=');
		let value = valueParts.join('=').trim();
		if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
			value = value.slice(1, -1);
		}
		if (key && process.env[key] === undefined) {
			process.env[key] = value;
		}
	}
}

function normalizeBaasUrl(configured = 'http://localhost:8000') {
	return configured.startsWith('/api') ? 'http://localhost:8000' : configured.replace(/\/$/, '');
}

export const config = {
	url: normalizeBaasUrl(process.env.PUBLIC_BAAS_URL),
	anonKey: process.env.PUBLIC_BAAS_ANON_KEY ?? '',
	allowedOrigin: process.env.SECURITY_ALLOWED_ORIGIN ?? 'http://localhost:4322',
	disallowedOrigin: process.env.SECURITY_DISALLOWED_ORIGIN ?? 'http://evil.example.com',
	testEmail: process.env.SECURITY_TEST_EMAIL ?? `devfast+security-${Date.now()}@archicode.codes`,
	testPassword: process.env.SECURITY_TEST_PASSWORD ?? 'Test123!',
};

let securityUserReady;

export async function ensureSecurityTestUser() {
	if (!securityUserReady) {
		securityUserReady = (async () => {
			const { createServiceBaasClient } = await import('../baas-env.mjs');
			try {
				await createServiceBaasClient().auth.admin.createUser({
					email: config.testEmail,
					password: config.testPassword,
					email_confirm: true,
				});
			} catch (error) {
				const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
				if (!message.includes('already') && !message.includes('registered') && !message.includes('exists')) {
					throw error;
				}
			}
			try {
				await createServiceBaasClient().from('users').insert({
					username: config.testEmail.split('@')[0].replaceAll(/[^a-z0-9_-]/gi, '-'),
					email: config.testEmail,
					password_hash: ['managed', 'by', 'gotrue'].join('-'),
					theme: 'light',
					notifications_enabled: true,
					is_email_verified: true,
				});
			} catch (error) {
				const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
				if (!message.includes('duplicate') && !message.includes('already') && !message.includes('unique')) {
					throw error;
				}
			}
		})();
	}
	return securityUserReady;
}

export { assert };

export function requireBaasConfig() {
	assert.ok(config.url, 'PUBLIC_BAAS_URL is required.');
	assert.ok(config.anonKey, 'PUBLIC_BAAS_ANON_KEY is required.');
	return config;
}

export function restUrl(path) {
	return `${config.url}/rest/v1${normalizePath(path)}`;
}

export function authUrl(path) {
	return `${config.url}/auth/v1${normalizePath(path)}`;
}

export function storageUrl(path) {
	return `${config.url}/storage/v1${normalizePath(path)}`;
}

function normalizePath(path) {
	return path.startsWith('/') ? path : `/${path}`;
}

export function baasHeaders(extra = {}) {
	requireBaasConfig();
	return {
		apikey: config.anonKey,
		Authorization: `Bearer ${config.anonKey}`,
		Accept: 'application/json',
		...extra,
	};
}

export async function fetchWithTimeout(url, options = {}, timeoutMs = 5000) {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), timeoutMs);
	try {
		return await fetch(url, { ...options, signal: controller.signal });
	} finally {
		clearTimeout(timer);
	}
}

export async function textBody(response) {
	return await response.text().catch(() => '');
}

export async function jsonBody(response) {
	return await response.json().catch(() => null);
}

export function headerList(value) {
	return (value ?? '')
		.split(',')
		.map((item) => item.trim().toLowerCase())
		.filter(Boolean);
}

export function isJsonResponse(response) {
	return (response.headers.get('content-type') ?? '').toLowerCase().includes('application/json');
}

export function isJwtLike(value) {
	return typeof value === 'string' && /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value);
}

export function noInternalLeak(body) {
	const content = String(body ?? '').toLowerCase();
	const blockedFragments = [
		'stack trace',
		'traceback',
		'/app/',
		'/usr/',
		'postgres',
		'sqlstate',
		'psql',
		'database error',
		'syntax error at or near',
	];
	const stackFramePattern = /\bat\s+\S+:\d+:\d+/i;
	return !blockedFragments.some((fragment) => content.includes(fragment)) && !stackFramePattern.test(body ?? '');
}

export function safePublicColumns(row) {
	const allowed = new Set([
		'id',
		'username',
		'email',
		'first_name',
		'last_name',
		'avatar_url',
		'bio',
		'theme',
		'notifications_enabled',
		'is_email_verified',
		'created_at',
		'updated_at',
	]);
	return Object.keys(row ?? {}).every((key) => allowed.has(key));
}

export async function authPasswordGrant(email = config.testEmail, password = config.testPassword, timeoutMs = 5000) {
	return await fetchWithTimeout(
		authUrl('/token?grant_type=password'),
		{
			method: 'POST',
			headers: {
				apikey: config.anonKey,
				Accept: 'application/json',
				'Content-Type': 'application/json',
			},
			body: JSON.stringify({ email, password }),
		},
		timeoutMs,
	);
}

export async function runChecks(checks) {
	const results = [];
	for (const check of checks) {
		try {
			const outcome = (await check.run()) ?? {};
			results.push({
				name: check.name,
				description: check.description,
				status: outcome.status ?? 'passed',
				message: outcome.message ?? check.description,
			});
		} catch (error) {
			results.push({
				name: check.name,
				description: check.description,
				status: 'failed',
				message: error instanceof Error ? error.message : String(error),
			});
		}
	}

	return summarize(results);
}

export function summarize(results) {
	return {
		passed: results.filter((result) => result.status === 'passed').length,
		failed: results.filter((result) => result.status === 'failed').length,
		skipped: results.filter((result) => result.status === 'skipped').length,
		results,
	};
}

export function skipped(message) {
	return { status: 'skipped', message };
}

export function passed(message) {
	return { status: 'passed', message };
}

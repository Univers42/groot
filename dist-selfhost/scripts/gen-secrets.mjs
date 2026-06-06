#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   gen-secrets.mjs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/06 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/06 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Generates ALL secrets for a self-hosted Track-Binocle install into a single
// ./.env — fully OFFLINE, no Vault, no monorepo. Idempotent (setIfMissing): safe
// to re-run; never overwrites an existing value.
//
// CRITICAL: ANON_KEY / SERVICE_ROLE_KEY are HS256 JWTs CO-SIGNED by the generated
// JWT_SECRET, so they validate against kong/gotrue/postgrest in this same install.
// signJwt() is copied VERBATIM from apps/baas/scripts/bootstrap-env.mjs — keep it
// byte-identical so the key pair stays valid.

import { createHmac, randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const target = resolve(process.cwd(), '.env');

function parseEnv(path) {
	const values = new Map();
	if (!existsSync(path)) return values;
	for (const rawLine of readFileSync(path, 'utf8').split(/\r?\n/)) {
		const line = rawLine.trim();
		if (!line || line.startsWith('#') || !line.includes('=')) continue;
		const [key, ...rest] = line.split('=');
		let value = rest.join('=').trim();
		if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
		values.set(key.trim(), value);
	}
	return values;
}

function base64url(input) {
	return Buffer.from(input).toString('base64url');
}

// VERBATIM from apps/baas/scripts/bootstrap-env.mjs — do not diverge.
function signJwt(secret, role) {
	const now = Math.floor(Date.now() / 1000);
	const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
	const payload = base64url(JSON.stringify({ role, iss: 'supabase', iat: now, exp: now + 60 * 60 * 24 * 3650 }));
	const signature = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
	return `${header}.${payload}.${signature}`;
}

const v = parseEnv(target);
const set = (key, value) => { if (!v.get(key)) v.set(key, value); };
const osionosSecret = () => randomBytes(48).toString('base64url');

// --- core database + JWT key pair ---------------------------------------
set('POSTGRES_USER', 'postgres');
set('POSTGRES_DB', 'postgres');
set('POSTGRES_PASSWORD', randomBytes(24).toString('base64url'));
set('PGRST_DB_ANON_ROLE', 'anon');
set('KONG_ANON_UUID', 'cd4f782c-ac87-5081-b322-b54834d15651');
set('JWT_SECRET', randomBytes(32).toString('hex'));
const jwt = v.get('JWT_SECRET');
set('ANON_KEY', signJwt(jwt, 'anon'));
set('SERVICE_ROLE_KEY', signJwt(jwt, 'service_role'));
set('KONG_PUBLIC_API_KEY', v.get('ANON_KEY'));
set('KONG_SERVICE_API_KEY', v.get('SERVICE_ROLE_KEY'));

const dbUrl = `postgres://${encodeURIComponent(v.get('POSTGRES_USER'))}:${encodeURIComponent(v.get('POSTGRES_PASSWORD'))}@postgres:5432/${encodeURIComponent(v.get('POSTGRES_DB'))}`;
v.set('DATABASE_URL', dbUrl);
v.set('PGRST_DB_URI', dbUrl);
v.set('GOTRUE_DB_DATABASE_URL', dbUrl);
set('PGRST_JWT_SECRET', jwt);
set('GOTRUE_JWT_SECRET', jwt);
set('PROJECT_INIT_MARKER', 'track_binocle_20260504');
set('PG_META_DB_HOST', 'postgres');
set('PG_META_DB_PORT', '5432');
set('PG_META_DB_NAME', v.get('POSTGRES_DB'));
set('PG_META_DB_USER', v.get('POSTGRES_USER'));
v.set('PG_META_DB_PASSWORD', v.get('POSTGRES_PASSWORD'));
set('SECRET_KEY_BASE', randomBytes(48).toString('base64url'));
set('VAULT_ENC_KEY', randomBytes(16).toString('hex'));

// --- GoTrue: local Mailpit + site config --------------------------------
set('GOTRUE_SMTP_HOST', 'mailpit');
set('GOTRUE_SMTP_PORT', '1025');
set('GOTRUE_SMTP_USER', '');
set('GOTRUE_SMTP_PASS', '');
set('GOTRUE_SMTP_ADMIN_EMAIL', 'noreply@mini-baas.local');
set('GOTRUE_SMTP_SENDER_NAME', 'Prismatica');
set('GOTRUE_SITE_URL', 'https://localhost:4322');
set('GOTRUE_URI_ALLOW_LIST', 'https://localhost:4322/**,https://localhost:3001/**,http://localhost:4322/**,http://localhost:3001/**');
set('GOTRUE_MAILER_AUTOCONFIRM', 'true');

// --- osionos bridge runtime secrets -------------------------------------
set('OSIONOS_BRIDGE_SHARED_SECRET', osionosSecret());
set('OSIONOS_APP_SESSION_SECRET', osionosSecret());
set('OSIONOS_BRIDGE_EMAIL_HASH_SALT', osionosSecret());
set('OSIONOS_APP_URL', 'https://localhost:3001');
set('OSIONOS_ALLOWED_ORIGIN', 'https://localhost:3001');
set('PUBLIC_OSIONOS_APP_URL', 'https://localhost:3001');

// --- auth-gateway behaviour (local: Turnstile bypassed, mail via Mailpit) -
set('TURNSTILE_BYPASS_LOCAL', 'true');
set('TURNSTILE_SECRET_KEY', '');
set('AUTH_REQUIRE_EMAIL_VERIFICATION', 'false');
set('SMTP_HOST', 'mailpit');
set('SMTP_PORT', '1025');
set('SMTP_ENCRYPTION', 'none');
set('SMTP_FROM_ADDRESS', 'noreply@mini-baas.local');
set('SMTP_FROM_NAME', 'Prismatica');

// --- public site / browser-exposed --------------------------------------
set('PUBLIC_SITE_URL', 'https://localhost:4322');
set('PUBLIC_BAAS_ANON_KEY', v.get('KONG_PUBLIC_API_KEY'));

const out = [...v.entries()].map(([key, value]) => `${key}=${value}`).join('\n');
writeFileSync(target, `${out}\n`, { mode: 0o600 });
console.log(`[gen-secrets] wrote ${target} (${v.size} keys; JWT-co-signed anon/service pair)`);

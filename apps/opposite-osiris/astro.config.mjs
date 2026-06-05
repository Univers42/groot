/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   astro.config.mjs                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// @ts-nocheck
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { loadEnv } from 'vite';

const env = loadEnv(process.env.NODE_ENV ?? 'development', process.cwd(), '');
const authGatewayTarget = env.AUTH_GATEWAY_TARGET ?? `http://localhost:${env.AUTH_GATEWAY_PORT ?? 8787}`;
const baasGatewayTarget = env.BAAS_GATEWAY_TARGET ?? 'http://localhost:8000';
const defaultCertDir = resolve(process.cwd(), '../../apps/baas/certs');
const devHttpsEnabled = env.ASTRO_DEV_HTTPS === 'true';
const devHttpsKey = resolve(process.cwd(), env.ASTRO_DEV_HTTPS_KEY ?? `${defaultCertDir}/localhost-key.pem`);
const devHttpsCert = resolve(process.cwd(), env.ASTRO_DEV_HTTPS_CERT ?? `${defaultCertDir}/localhost.pem`);

function localHttpsConfig() {
	if (!devHttpsEnabled) {
		return undefined;
	}
	if (!existsSync(devHttpsKey) || !existsSync(devHttpsCert)) {
		throw new Error(`Local HTTPS was requested but the certificate files are missing. Start the Docker stack or generate the localhost certificate from the project-owned BaaS scripts. Expected key: ${devHttpsKey}. Expected cert: ${devHttpsCert}.`);
	}
	return {
		key: readFileSync(devHttpsKey),
		cert: readFileSync(devHttpsCert),
	};
}

function devContentSecurityPolicy() {
	return [
		"default-src 'self'",
		"base-uri 'self'",
		"object-src 'none'",
		"frame-ancestors 'self'",
		"form-action 'self'",
		"img-src 'self' data: blob:",
		"media-src 'self' data: blob:",
		"worker-src 'self' blob:",
		"manifest-src 'self'",
		"font-src 'self'",
		"style-src 'self' 'unsafe-inline'",
		"script-src 'self' 'unsafe-inline' 'unsafe-eval' https://challenges.cloudflare.com",
		"connect-src 'self' http://localhost:* https://localhost:* ws://localhost:* wss://localhost:*",
	].join('; ');
}

// https://astro.build/config
export default defineConfig({
	// Canonical origin for sitemap + <link rel="canonical">. Override per
	// environment with PUBLIC_SITE_URL (compose sets it; prod sets the real domain).
	site: env.PUBLIC_SITE_URL ?? 'https://localhost:4322',
	integrations: [sitemap()],
	devToolbar: { enabled: false },
	// Inline all page CSS into <style> tags instead of render-blocking <link>s.
	// On the landing page this removes two critical-path round-trips (~1.2s of
	// blocked FCP under mobile throttling). Astro's security.csp auto-hashes the
	// inline styles it emits, so style-src stays strict ('self' + hashes) and
	// scripts/audit/csp-check.mjs proves no CSP violation in headless Chromium.
	build: { inlineStylesheets: 'always' },
	// No markdown code blocks exist in this site (no .md/.mdx, no <Code>), so the
	// default Shiki highlighter is dead weight AND emits a build-time CSP warning
	// (Shiki uses inline styles). Disable it to keep the build warning-free.
	markdown: { syntaxHighlight: false },
	// Astro generates a per-page CSP <meta> with SHA-256 hashes for every inline
	// script/style it emits (Astro inlines small hoisted module scripts). This is
	// what keeps `script-src` strict — 'self' + hashes, NO 'unsafe-inline'. We add
	// the external script origins (bundle 'self' + Turnstile) and allow inline
	// style ATTRIBUTES (the `--i`/`--node-color` props, which cannot be hashed).
	security: {
		csp: {
			directives: [
				"default-src 'self'",
				"base-uri 'self'",
				"object-src 'none'",
				// NOTE: `frame-ancestors` is intentionally NOT here. Astro emits this
				// CSP via <meta>, and browsers IGNORE frame-ancestors in <meta> (and
				// log a console error). Clickjacking is enforced at the HTTP layer
				// instead — the proxy sets `X-Frame-Options: DENY` and a real
				// `Content-Security-Policy: frame-ancestors 'none'` response header.
				"form-action 'self'",
				"img-src 'self'",
				"media-src 'self'",
				"worker-src 'self'",
				"manifest-src 'self'",
				"font-src 'self'",
				"connect-src 'self' https:",
				"trusted-types prismatica-static-markup",
				"require-trusted-types-for 'script'",
			],
			scriptDirective: { resources: ["'self'", 'https://challenges.cloudflare.com'] },
			// No inline style= attributes remain in live pages, so style-src needs
			// only 'self' (external CSS) + Astro's per-page <style> hashes — no
			// 'unsafe-inline'. scripts/audit/csp-check.mjs guards this.
			styleDirective: { resources: ["'self'"] },
		},
	},
	server: {
		host: env.ASTRO_DEV_HOST ?? 'localhost',
		port: Number(env.ASTRO_DEV_PORT ?? 4322),
	},
	vite: {
		server: {
			host: env.ASTRO_DEV_HOST ?? 'localhost',
			port: Number(env.ASTRO_DEV_PORT ?? 4322),
			https: localHttpsConfig(),
			headers: {
				'Content-Security-Policy': devContentSecurityPolicy(),
				'X-Prismatica-CSP-Mode': 'development',
			},
			proxy: {
				'/api/auth': {
					target: authGatewayTarget,
					changeOrigin: true,
					secure: false,
				},
				'/api/newsletter': {
					target: authGatewayTarget,
					changeOrigin: true,
					secure: false,
				},
				'/api': {
					target: baasGatewayTarget,
					changeOrigin: true,
					secure: false,
					rewrite: (path) => path.replace(/^\/api/, ''),
					configure: (proxy) => {
						const proxyEvents = /** @type {{ on(event: 'proxyReq', listener: (proxyReq: { setHeader(name: string, value: string): void }, request: { headers: Record<string, string | string[] | undefined> }) => void): void }} */ (/** @type {unknown} */ (proxy));
						proxyEvents.on('proxyReq', (proxyReq, request) => {
							const apikey = request.headers.apikey;
							if (Array.isArray(apikey)) {
								proxyReq.setHeader('apikey', apikey[0] ?? '');
							} else if (apikey) {
								proxyReq.setHeader('apikey', apikey);
							}
						});
					},
				},
			},
		},
	},
});

// @ts-nocheck
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig } from 'astro/config';
import { loadEnv } from 'vite';

const env = loadEnv(process.env.NODE_ENV ?? 'development', process.cwd(), '');
const authGatewayTarget = `http://localhost:${env.AUTH_GATEWAY_PORT ?? 8787}`;
const defaultCertDir = resolve(process.cwd(), '../../infrastructure/baas/certs');
const devHttpsEnabled = env.ASTRO_DEV_HTTPS === 'true' || env.PUBLIC_SITE_URL?.startsWith('https://localhost');
const devHttpsKey = resolve(process.cwd(), env.ASTRO_DEV_HTTPS_KEY ?? `${defaultCertDir}/localhost-key.pem`);
const devHttpsCert = resolve(process.cwd(), env.ASTRO_DEV_HTTPS_CERT ?? `${defaultCertDir}/localhost.pem`);

function localHttpsConfig() {
	if (!devHttpsEnabled) {
		return undefined;
	}
	if (!existsSync(devHttpsKey) || !existsSync(devHttpsCert)) {
		throw new Error(`Local HTTPS was requested but the certificate files are missing. Run npm run cert:localhost, then restart Astro with npm run dev:https. Expected key: ${devHttpsKey}. Expected cert: ${devHttpsCert}.`);
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
		"font-src 'self' https://fonts.gstatic.com",
		"style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
		"script-src 'self' 'unsafe-inline' 'unsafe-eval' https://challenges.cloudflare.com",
		"connect-src 'self' http://localhost:* https://localhost:* ws://localhost:* wss://localhost:*",
	].join('; ');
}

// https://astro.build/config
export default defineConfig({
	devToolbar: { enabled: false },
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
					target: 'http://localhost:8000',
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

#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { constants, accessSync, existsSync } from 'node:fs';
import { connect } from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(projectDir, '../..');
const certDir = resolve(repoRoot, 'infrastructure/baas/certs');
const certScript = resolve(repoRoot, 'infrastructure/baas/scripts/generate-localhost-cert.sh');
const trustScript = resolve(repoRoot, 'infrastructure/baas/scripts/trust-localhost-cert.sh');
const caFile = resolve(certDir, 'track-binocle-local-ca.pem');
const certFile = resolve(certDir, 'localhost.pem');
const keyFile = resolve(certDir, 'localhost-key.pem');
const host = process.env.ASTRO_DEV_HOST ?? 'localhost';
const port = Number(process.env.ASTRO_DEV_PORT ?? 4322);
const authGatewayPort = Number(process.env.AUTH_GATEWAY_PORT ?? 8787);
const authGatewayScript = resolve(projectDir, 'scripts/auth-gateway.mjs');
const astroBin = resolve(projectDir, 'node_modules/.bin/astro');
const shellPath = '/bin/sh';
const socketStatsPath = '/usr/bin/ss';
let authGatewayChild;

function fail(message) {
	console.error(`\n${message}\n`);
	process.exit(1);
}

function assertReadable(filePath, description) {
	try {
		accessSync(filePath, constants.R_OK);
	} catch {
		fail(`${description} is missing or unreadable: ${filePath}`);
	}
}

function ensureCertificates() {
	if (existsSync(caFile) && existsSync(certFile) && existsSync(keyFile)) {
		return;
	}

	if (!existsSync(certScript)) {
		fail(`Local HTTPS certificates are missing and the generator was not found: ${certScript}`);
	}

	console.log('Local HTTPS certificates are missing; generating them from the project-owned BaaS scripts.');
	const result = spawnSync(shellPath, [certScript], {
		cwd: projectDir,
		stdio: 'inherit',
	});

	if (result.status !== 0) {
		fail('Local HTTPS certificate generation failed.');
	}

	assertReadable(certFile, 'Local HTTPS certificate');
	assertReadable(keyFile, 'Local HTTPS private key');
}

function ensureCertificateTrust() {
	if (!existsSync(trustScript)) {
		fail(`Local HTTPS trust script is missing: ${trustScript}`);
	}
	const result = spawnSync(shellPath, [trustScript], {
		cwd: projectDir,
		stdio: 'inherit',
	});
	if (result.status !== 0) {
		fail('Local HTTPS CA trust setup failed. Install libnss3-tools or run the trust-localhost-cert.sh helper from Docker.');
	}
}

function canConnect(address, targetPort = port) {
	return new Promise((resolveConnection) => {
		const socket = connect({ host: address, port: targetPort, timeout: 350 });
		socket.once('connect', () => {
			socket.destroy();
			resolveConnection(true);
		});
		socket.once('timeout', () => {
			socket.destroy();
			resolveConnection(false);
		});
		socket.once('error', () => resolveConnection(false));
	});
}

async function isListening(targetPort) {
	const addresses = ['127.0.0.1', '::1'];
	const results = await Promise.all(addresses.map((address) => canConnect(address, targetPort)));
	return results.some(Boolean);
}

async function assertPortAvailable() {
	const addresses = ['127.0.0.1', '::1'];
	const results = await Promise.all(addresses.map((address) => canConnect(address, port)));
	if (!results.some(Boolean)) {
		return;
	}

	const listenerInfo = spawnSync(socketStatsPath, ['-ltnp'], {
		encoding: 'utf8',
	});
	const listenerLines = listenerInfo.stdout
		.split('\n')
		.filter((line) => line.includes(`:${port}`))
		.join('\n')
		.trim();
	const details = listenerLines ? `\n\nCurrent listener:\n${listenerLines}` : '';
	fail(`Port ${port} is already in use. Stop the existing dev server first, then restart the Docker stack. If that server is plain HTTP, browsers show ERR_SSL_PROTOCOL_ERROR for https://localhost:${port}.${details}`);
}

async function ensureAuthGateway() {
	if (!String(process.env.PUBLIC_AUTH_GATEWAY_URL ?? '/api/auth').startsWith('/api/auth')) {
		return;
	}
	if (await isListening(authGatewayPort)) {
		console.log(`Auth gateway already listening at http://localhost:${authGatewayPort}/`);
		return;
	}
	if (!existsSync(authGatewayScript)) {
		fail(`Auth gateway proxy is configured but the script is missing: ${authGatewayScript}`);
	}
	console.log(`Starting auth gateway at http://localhost:${authGatewayPort}/ for /api/auth proxy routes.`);
	authGatewayChild = spawn(process.execPath, [authGatewayScript], {
		cwd: projectDir,
		env: {
			...process.env,
			AUTH_GATEWAY_PORT: String(authGatewayPort),
			PUBLIC_SITE_URL: process.env.PUBLIC_SITE_URL ?? `https://localhost:${port}`,
		},
		stdio: 'inherit',
	});
	await new Promise((resolveReady) => setTimeout(resolveReady, 600));
	if (!(await isListening(authGatewayPort))) {
		fail(`Auth gateway did not start on port ${authGatewayPort}.`);
	}
}

ensureCertificates();
ensureCertificateTrust();
await assertPortAvailable();
await ensureAuthGateway();
assertReadable(certFile, 'Local HTTPS certificate');
assertReadable(keyFile, 'Local HTTPS private key');

const env = {
	...process.env,
	ASTRO_DEV_HOST: host,
	ASTRO_DEV_PORT: String(port),
	ASTRO_DEV_HTTPS: 'true',
	ASTRO_DEV_HTTPS_CERT: certFile,
	ASTRO_DEV_HTTPS_KEY: keyFile,
	PUBLIC_SITE_URL: process.env.PUBLIC_SITE_URL ?? `https://localhost:${port}`,
};

console.log(`Starting Astro with HTTPS at https://localhost:${port}/`);
const child = spawn(astroBin, ['dev', '--host', host, '--port', String(port)], {
	cwd: projectDir,
	env,
	stdio: 'inherit',
});

child.on('exit', (code, signal) => {
	authGatewayChild?.kill('SIGTERM');
	if (signal) {
		process.kill(process.pid, signal);
		return;
	}
	process.exit(code ?? 0);
});

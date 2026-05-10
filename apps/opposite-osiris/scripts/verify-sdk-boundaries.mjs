#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { relative, resolve } from 'node:path';

const repoRoot = resolve(import.meta.dirname, '../..');
const forbidden = [
	{ label: 'raw PostgREST path', pattern: /\/rest\/v1/ },
	{ label: 'raw GoTrue path', pattern: /\/auth\/v1/ },
	{ label: 'local BaaS gateway literal', pattern: /localhost:8000|127\.0\.0\.1:8000/ },
	{ label: 'raw mini-baas-infra runtime path', pattern: /mini-baas-infra/ },
];

const roots = [
	'opposite-osiris/src',
	'opposite-osiris/scripts',
	'opposite-osiris/astro.config.mjs',
	'docker-compose.yml',
	'apps/baas',
];

const allowed = [
	/^opposite-osiris\/astro\.config\.mjs$/,
	/^opposite-osiris\/scripts\/security\//,
	/^opposite-osiris\/scripts\/verify-cors\.mjs$/,
	/^opposite-osiris\/scripts\/verify-sdk-boundaries\.mjs$/,
	/^opposite-osiris\/scripts\/auth-gateway\.mjs$/,
	/^opposite-osiris\/scripts\/baas-env\.mjs$/,
	/^opposite-osiris\/README\.md$/,
	/^infrastructure\/baas\/sdk\/src\/core\/routes\.ts$/,
	/^infrastructure\/baas\/mini-baas-infra\//,
	/^infrastructure\/baas\/mini-baas-infra\.__disabled_for_runtime_test\//,
	/^infrastructure\/baas\/config\/mini-baas-infra\.conf$/,
	/^infrastructure\/baas\/config\/kong\.track-binocle\.yml$/,
	/^infrastructure\/baas\/config\/README\.md$/,
	/^infrastructure\/baas\/Dockerfile$/,
	/^docker-compose\.yml$/,
];

const extensions = new Set(['.astro', '.js', '.mjs', '.ts', '.tsx', '.json', '.yml', '.yaml', '.md', '.conf', '.sh']);
const issues = [];

for (const root of roots) {
	collect(resolve(repoRoot, root));
}

function collect(path) {
	const stat = statSync(path);
	if (stat.isDirectory()) {
		for (const entry of readdirSync(path)) {
			if (entry === 'node_modules' || entry === 'dist' || entry === 'certs') continue;
			collect(resolve(path, entry));
		}
		return;
	}
	const rel = relative(repoRoot, path).replaceAll('\\', '/');
	if (allowed.some((pattern) => pattern.test(rel))) return;
	if (!extensions.has(path.slice(path.lastIndexOf('.')))) return;
	const text = readFileSync(path, 'utf8');
	for (const rule of forbidden) {
		const match = text.match(rule.pattern);
		if (match) issues.push(`${rel}: contains ${rule.label} (${match[0]})`);
	}
}

if (issues.length > 0) {
	console.error('SDK boundary check failed:');
	for (const issue of issues) console.error(`- ${issue}`);
	process.exit(1);
}

console.log('PASS Normal app/runtime code uses the SDK boundary for BaaS access.');

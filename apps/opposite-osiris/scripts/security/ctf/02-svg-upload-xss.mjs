#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { assert, projectRoot, publicRoot, runChecks, srcRoot, summarize, walkFiles } from './_shared.mjs';
import { sanitizeSvgMarkup } from '../../../src/lib/svg-security.mjs';

const SVG_FILE_PATTERN = /\.svg$/iu;
const DANGEROUS_SVG_PATTERNS = [
	/<\s*script\b/iu,
	/<\s*foreignObject\b/iu,
	/\son[a-z]+\s*=/iu,
	/(?:href|xlink:href|src)\s*=\s*['"]?\s*(?:javascript:|vbscript:)/iu,
	/(?:href|xlink:href|src)\s*=\s*['"]?\s*data:\s*(?:text\/html|image\/svg\+xml)/iu,
	/<\s*(?:iframe|object|embed|link|meta)\b/iu,
	/@import\b/iu,
	/url\(\s*['"]?\s*(?:javascript:|data:\s*(?:text\/html|image\/svg\+xml))/iu,
];

const maliciousPayloads = [
	'<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><path d="M0 0" /></svg>',
	'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><path d="M0 0" /></svg>',
	'<svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(1)"><text>click</text></a></svg>',
	'<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><img src=x onerror=alert(1)></foreignObject></svg>',
	'<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/svg+xml,<svg onload=alert(1)>" /></svg>',
	'<svg xmlns="http://www.w3.org/2000/svg"><style>@import url(https://evil.example/x.css)</style><path d="M0 0" /></svg>',
];

function svgFiles() {
	return [
		...walkFiles(srcRoot, (path) => SVG_FILE_PATTERN.test(path)),
		...walkFiles(publicRoot, (path) => SVG_FILE_PATTERN.test(path)),
	];
}

function inlineSvgFiles() {
	return walkFiles(`${srcRoot}/assets/draw`, (path) => SVG_FILE_PATTERN.test(path));
}

export async function run() {
	return summarize(await runChecks([
		{
			name: 'Checked-in SVG assets contain no active content primitives',
			run: () => {
				const offenders = svgFiles().filter((file) => {
					const content = readFileSync(file, 'utf8');
					return DANGEROUS_SVG_PATTERNS.some((pattern) => pattern.test(content));
				});
				assert.deepEqual(offenders.map((file) => file.replace(`${projectRoot}/`, '')), [], 'Dangerous SVG primitives found in checked-in assets');
			},
		},
		{
			name: 'Sanitizer accepts legitimate inline illustration SVGs',
			run: () => {
				for (const file of inlineSvgFiles()) {
					const sanitized = sanitizeSvgMarkup(readFileSync(file, 'utf8'));
					assert.ok(sanitized.startsWith('<svg'), `${file} did not sanitize to SVG markup`);
				}
			},
		},
		{
			name: 'Sanitizer blocks SVG upload XSS payloads',
			run: () => {
				for (const payload of maliciousPayloads) {
					assert.throws(() => sanitizeSvgMarkup(payload), /Unsafe SVG|Sanitized SVG/u);
				}
			},
		},
	]));
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const result = await run();
	console.log(JSON.stringify(result, null, 2));
	process.exitCode = result.failed > 0 ? 1 : 0;
}

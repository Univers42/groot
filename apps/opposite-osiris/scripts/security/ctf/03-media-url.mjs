#!/usr/bin/env node
import { assert, readProjectFile, runChecks, summarize } from './_shared.mjs';
import { safePublicAssetPath } from '../../../src/lib/media-security.mjs';

const acceptedMedia = [
	'image%206.svg',
	'span (1).svg',
	'product.png.svg',
	'workspace.png',
	'hero.webp',
];

const rejectedMedia = [
	'../secret.svg',
	'..%2Fsecret.svg',
	'nested/file.svg',
	'javascript:alert(1).svg',
	'data:image/svg+xml,<svg onload=alert(1)>.svg',
	'https://evil.example/payload.svg',
	'payload.svg?download=1',
	'payload.svg#<script>',
	'payload.html',
	'payload.svg\0.png',
];

export async function run() {
	return summarize(await runChecks([
		{
			name: 'Safe media helper accepts checked-in asset names',
			run: () => {
				for (const name of acceptedMedia) {
					const url = safePublicAssetPath(name, '/base/');
					assert.ok(url.startsWith('/base/assets/'), `${name} produced unexpected URL ${url}`);
					assert.ok(!url.includes('javascript:'), `${name} produced executable protocol`);
				}
			},
		},
		{
			name: 'Safe media helper rejects traversal and executable protocols',
			run: () => {
				for (const name of rejectedMedia) {
					assert.throws(() => safePublicAssetPath(name, '/'), /Unsafe public asset path/u, `${name} should be rejected`);
				}
			},
		},
		{
			name: 'MediaAssetsSection uses safePublicAssetPath',
			run: () => {
				const section = readProjectFile('src/components/sections/MediaAssetsSection.astro');
				assert.ok(section.includes('safePublicAssetPath'), 'MediaAssetsSection must use the media URL allowlist helper');
				assert.ok(!section.includes('`${import.meta.env.BASE_URL}assets/${fileName}`'), 'raw path concatenation must not return');
			},
		},
	]));
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const result = await run();
	console.log(JSON.stringify(result, null, 2));
	process.exitCode = result.failed > 0 ? 1 : 0;
}

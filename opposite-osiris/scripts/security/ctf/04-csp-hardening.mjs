#!/usr/bin/env node
import { assert, readProjectFile, runChecks, summarize } from './_shared.mjs';

function extractArrayBlock(source, name) {
	const start = source.indexOf(`const ${name} = [`);
	assert.ok(start >= 0, `${name} not found`);
	const end = source.indexOf('].join', start);
	assert.ok(end >= 0, `${name} join not found`);
	return source.slice(start, end);
}

export async function run() {
	return summarize(await runChecks([
		{
			name: 'Production meta CSP blocks active document gadgets',
			run: () => {
				const layout = readProjectFile('src/layouts/Layout.astro');
				const csp = extractArrayBlock(layout, 'productionCsp');
				for (const directive of [
					"default-src 'self'",
					"base-uri 'self'",
					"object-src 'none'",
					"form-action 'self'",
					"img-src 'self'",
					"media-src 'self'",
					"worker-src 'self'",
					"trusted-types prismatica-static-markup",
					"require-trusted-types-for 'script'",
				]) {
					assert.ok(csp.includes(directive), `production CSP missing ${directive}`);
				}
				assert.ok(!csp.includes('frame-ancestors'), 'frame-ancestors is ignored in meta CSP and must not be present there');
				assert.ok(!csp.includes("'unsafe-inline'"), 'production CSP must not allow unsafe-inline');
				assert.ok(!csp.includes("'unsafe-eval'"), 'production CSP must not allow unsafe-eval');
				assert.ok(!/img-src[^"\n]*\b(?:blob:|data:)/u.test(csp), 'production img-src must not allow blob: or data:');
			},
		},
		{
			name: 'Development meta CSP marks unsafe allowances as dev-only',
			run: () => {
				const layout = readProjectFile('src/layouts/Layout.astro');
				const csp = extractArrayBlock(layout, 'developmentCsp');
				assert.ok(csp.includes("'unsafe-inline'"), 'development CSP may keep Vite inline allowance');
				assert.ok(csp.includes("'unsafe-eval'"), 'development CSP may keep Vite eval allowance');
				assert.ok(!csp.includes('frame-ancestors'), 'frame-ancestors is ignored in meta CSP and must not be present there');
			},
		},
		{
			name: 'Production static headers carry frame-ancestors',
			run: () => {
				const headers = readProjectFile('public/_headers');
				assert.ok(headers.includes('Content-Security-Policy:'), 'production static CSP header missing');
				assert.ok(headers.includes("frame-ancestors 'self'"), 'production static CSP header missing frame-ancestors');
			},
		},
		{
			name: 'Astro dev server emits a CSP header',
			run: () => {
				const config = readProjectFile('astro.config.mjs');
				assert.ok(config.includes("'Content-Security-Policy': devContentSecurityPolicy()"), 'dev server CSP header missing');
				assert.ok(config.includes("frame-ancestors 'self'"), 'dev CSP header missing frame-ancestors');
			},
		},
	]));
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const result = await run();
	console.log(JSON.stringify(result, null, 2));
	process.exitCode = result.failed > 0 ? 1 : 0;
}

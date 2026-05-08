#!/usr/bin/env node
import { assert, readProjectFile, relativeProjectPath, runChecks, srcRoot, summarize, walkFiles } from './_shared.mjs';

const SOURCE_EXTENSIONS = /\.(?:astro|ts|js|mjs)$/u;
const HTML_SINK_PATTERN = /(?:\.innerHTML\s*=|insertAdjacentHTML\s*\()/u;

function sourceFiles() {
	return walkFiles(srcRoot, (path) => SOURCE_EXTENSIONS.test(path));
}

export async function run() {
	return summarize(await runChecks([
		{
			name: 'Astro set:html must be SVG-sanitized',
			run: () => {
				const offenders = [];
				for (const file of sourceFiles()) {
					const text = readProjectFile(relativeProjectPath(file));
					if (text.includes('set:html=') && !text.includes('sanitizeSvgMarkup(')) {
						offenders.push(relativeProjectPath(file));
					}
				}
				assert.deepEqual(offenders, [], `Unsanitized set:html sinks: ${offenders.join(', ')}`);
			},
		},
		{
			name: 'Raw SVG imports require sanitizer in same module',
			run: () => {
				const offenders = [];
				for (const file of sourceFiles()) {
					const text = readProjectFile(relativeProjectPath(file));
					if (text.includes('?raw') && !text.includes('sanitizeSvgMarkup(')) {
						offenders.push(relativeProjectPath(file));
					}
				}
				assert.deepEqual(offenders, [], `Raw imports without sanitizer: ${offenders.join(', ')}`);
			},
		},
		{
			name: 'DOM HTML sinks are restricted to trusted wrappers',
			run: () => {
				const allowed = new Map([
					['src/scripts/main.ts', ['function setTrustedInnerHTML', 'function insertTrustedHTML', 'trustedHTML(markup)']],
				]);
				const offenders = [];
				for (const file of sourceFiles()) {
					const rel = relativeProjectPath(file);
					const text = readProjectFile(rel);
					if (!HTML_SINK_PATTERN.test(text)) continue;
					const markers = allowed.get(rel);
					if (markers?.every((marker) => text.includes(marker)) !== true) {
						offenders.push(rel);
					}
				}
				assert.deepEqual(offenders, [], `Unexpected HTML sink usage: ${offenders.join(', ')}`);
			},
		},
		{
			name: 'Trusted Types policy is app-scoped',
			run: () => {
				const main = readProjectFile('src/scripts/main.ts');
				assert.ok(main.includes("createPolicy('prismatica-static-markup'"), 'missing app-scoped Trusted Types policy');
				assert.ok(!main.includes("createPolicy('default'"), 'default Trusted Types policy must not be used');
			},
		},
		{
			name: 'User-controlled BaaS data renders with textContent',
			run: () => {
				const main = readProjectFile('src/scripts/main.ts');
				assert.ok(main.includes('name.textContent = user.username;'), 'seeded username must render via textContent');
				assert.ok(main.includes('email.textContent = user.email;'), 'seeded email must render via textContent');
			},
		},
	]));
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const result = await run();
	console.log(JSON.stringify(result, null, 2));
	process.exitCode = result.failed > 0 ? 1 : 0;
}

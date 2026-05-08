#!/usr/bin/env node
import * as xssSinks from './01-xss-sinks.mjs';
import * as svgUpload from './02-svg-upload-xss.mjs';
import * as mediaUrl from './03-media-url.mjs';
import * as csp from './04-csp-hardening.mjs';

const colors = {
	green: '\u001b[32m',
	red: '\u001b[31m',
	cyan: '\u001b[36m',
	bold: '\u001b[1m',
	reset: '\u001b[0m',
};

const categories = [
	{ key: 'xss-sinks', name: 'XSS sink inventory', module: xssSinks },
	{ key: 'svg-upload-xss', name: 'SVG upload XSS laboratory', module: svgUpload },
	{ key: 'media-url', name: 'Media URL injection laboratory', module: mediaUrl },
	{ key: 'csp', name: 'CSP and Trusted Types hardening', module: csp },
];

const selected = process.argv.find((arg) => arg.startsWith('--ctf-category='))?.split('=')[1]
	?? (import.meta.url === `file://${process.argv[1]}` ? process.argv.find((arg) => arg.startsWith('--category='))?.split('=')[1] : undefined);
const selectedCategories = selected ? categories.filter((category) => category.key === selected) : categories;

if (selected && selectedCategories.length === 0) {
	console.error(`${colors.red}Unknown CTF category:${colors.reset} ${selected}`);
	console.error(`Available: ${categories.map((category) => category.key).join(', ')}`);
	process.exit(1);
}

export async function run() {
	let passed = 0;
	let failed = 0;
	const results = [];

	for (const category of selectedCategories) {
		const result = await category.module.run();
		passed += result.passed;
		failed += result.failed;
		for (const item of result.results) {
			results.push({
				name: `${category.key}:${item.name}`,
				description: category.name,
				status: item.status,
				message: item.message,
			});
		}
	}

	return { passed, failed, skipped: 0, results };
}

if (import.meta.url === `file://${process.argv[1]}`) {
	console.log(`${colors.bold}${colors.cyan}Running Prismatica frontend CTF security laboratory${colors.reset}`);
	const result = await run();
	for (const category of selectedCategories) {
		const categoryResults = result.results.filter((item) => item.name.startsWith(`${category.key}:`));
		const categoryFailed = categoryResults.filter((item) => item.status === 'failed').length;
		const categoryPassed = categoryResults.filter((item) => item.status === 'passed').length;
		const color = categoryFailed > 0 ? colors.red : colors.green;
		console.log(`\n${colors.bold}${category.name}${colors.reset}`);
		console.log(`${color}passed=${categoryPassed} failed=${categoryFailed}${colors.reset}`);
		for (const item of categoryResults) {
			const marker = item.status === 'passed' ? `${colors.green}PASS${colors.reset}` : `${colors.red}FAIL${colors.reset}`;
			console.log(`  ${marker} ${item.name.slice(category.key.length + 1)} — ${item.message}`);
		}
	}

	const summaryColor = result.failed > 0 ? colors.red : colors.green;
	console.log(`\n${summaryColor}${colors.bold}CTF SECURITY LAB: ${result.passed} passed, ${result.failed} failed${colors.reset}`);
	process.exitCode = result.failed > 0 ? 1 : 0;
}

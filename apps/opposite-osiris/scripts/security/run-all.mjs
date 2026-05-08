#!/usr/bin/env node
import * as cors from './01-cors.mjs';
import * as auth from './02-auth.mjs';
import * as injection from './03-injection.mjs';
import * as xss from './04-xss.mjs';
import * as headers from './05-headers.mjs';
import * as sensitiveData from './06-sensitive-data.mjs';
import * as uploadPath from './07-upload-path.mjs';
import * as rateLimit from './08-rate-limit.mjs';
import * as gdpr from './09-gdpr.mjs';
import * as ctf from './ctf/run-all.mjs';

const colors = {
	green: '\u001b[32m',
	red: '\u001b[31m',
	yellow: '\u001b[33m',
	cyan: '\u001b[36m',
	bold: '\u001b[1m',
	reset: '\u001b[0m',
};

const categories = [
	{ key: 'cors', name: 'CORS policy validation', module: cors },
	{ key: 'injection', name: 'SQL injection and query manipulation', module: injection },
	{ key: 'xss', name: 'Cross-site scripting via stored data', module: xss },
	{ key: 'headers', name: 'HTTP security headers', module: headers },
	{ key: 'sensitive-data', name: 'Sensitive data exposure', module: sensitiveData },
	{ key: 'upload-path', name: 'File path and upload manipulation', module: uploadPath },
	{ key: 'rate-limit', name: 'Rate limiting and denial-of-service surface', module: rateLimit },
	{ key: 'gdpr', name: 'GDPR data protection controls', module: gdpr },
	{ key: 'ctf', name: 'Frontend CTF security laboratory', module: ctf },
	{ key: 'auth', name: 'Authentication and brute-force resistance', module: auth },
];

const categoryArg = process.argv.find((argument) => argument.startsWith('--category='));
const selectedKey = categoryArg?.split('=')[1];
const selectedCategories = selectedKey ? categories.filter((category) => category.key === selectedKey) : categories;

function markerForStatus(status) {
	if (status === 'passed') {
		return `${colors.green}PASS${colors.reset}`;
	}
	if (status === 'skipped') {
		return `${colors.yellow}SKIP${colors.reset}`;
	}
	return `${colors.red}FAIL${colors.reset}`;
}

if (selectedKey && selectedCategories.length === 0) {
	console.error(`${colors.red}Unknown category:${colors.reset} ${selectedKey}`);
	console.error(`Available categories: ${categories.map((category) => category.key).join(', ')}`);
	process.exit(1);
}

let totalPassed = 0;
let totalFailed = 0;
let totalSkipped = 0;

console.log(`${colors.bold}${colors.cyan}Running security suite against owned BaaS infrastructure${colors.reset}`);

for (const category of selectedCategories) {
	const result = await category.module.run();
	totalPassed += result.passed;
	totalFailed += result.failed;
	totalSkipped += result.skipped;

	const statusColor = result.failed > 0 ? colors.red : colors.green;
	console.log(`\n${colors.bold}${category.name}${colors.reset}`);
	console.log(`${statusColor}passed=${result.passed} failed=${result.failed}${colors.reset} ${colors.yellow}skipped=${result.skipped}${colors.reset}`);

	for (const item of result.results) {
		const marker = markerForStatus(item.status);
		console.log(`  ${marker} ${item.name} — ${item.message}`);
		if (item.status === 'failed') {
			console.log(`       ${item.description}`);
		}
	}
}

const summaryColor = totalFailed > 0 ? colors.red : colors.green;
console.log(`\n${summaryColor}${colors.bold}SECURITY SUITE: ${totalPassed} passed, ${totalFailed} failed, ${totalSkipped} skipped${colors.reset}`);

if (totalFailed > 0) {
	process.exitCode = 1;
}

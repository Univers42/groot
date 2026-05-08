#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import ts from 'typescript';

const sourcePath = resolve(process.cwd(), 'src/scripts/password-strength.ts');
const source = readFileSync(sourcePath, 'utf8');
const transpiled = ts.transpileModule(source, {
	compilerOptions: {
		module: ts.ModuleKind.ES2022,
		target: ts.ScriptTarget.ES2022,
		strict: true,
	},
}).outputText;

const moduleUrl = `data:text/javascript;base64,${Buffer.from(transpiled).toString('base64')}`;
const { checkPasswordStrength } = await import(moduleUrl);

const checks = [
	{
		name: 'empty password is empty and blocked',
		run: () => {
			const result = checkPasswordStrength('');
			assert.equal(result.level, 'empty');
			assert.equal(result.passed, false);
		},
	},
	{
		name: 'common password is weak and blocked',
		run: () => {
			const result = checkPasswordStrength('password');
			assert.equal(result.level, 'weak');
			assert.equal(result.passed, false);
		},
	},
	{
		name: 'Test123! is strong and accepted',
		run: () => {
			const result = checkPasswordStrength('Test123!');
			assert.equal(result.level, 'strong');
			assert.equal(result.passed, true);
		},
	},
	{
		name: 'abc is weak with multiple missing rules',
		run: () => {
			const result = checkPasswordStrength('abc');
			assert.equal(result.level, 'weak');
			assert.equal(result.passed, false);
			assert.ok(result.failedRules.length >= 3);
		},
	},
];

let failed = 0;
for (const check of checks) {
	try {
		check.run();
		console.log(`PASS ${check.name}`);
	} catch (error) {
		failed += 1;
		console.error(`FAIL ${check.name}: ${error instanceof Error ? error.message : String(error)}`);
	}
}

if (failed > 0) {
	process.exitCode = 1;
}

import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = fileURLToPath(new URL('.', import.meta.url));
export const projectRoot = resolve(scriptDir, '../../..');
export const srcRoot = resolve(projectRoot, 'src');
export const publicRoot = resolve(projectRoot, 'public');

export { assert };

export function readProjectFile(path) {
	return readFileSync(resolve(projectRoot, path), 'utf8');
}

export function projectPath(path) {
	return resolve(projectRoot, path);
}

export function relativeProjectPath(path) {
	return relative(projectRoot, path).replaceAll('\\', '/');
}

export function walkFiles(dir, predicate = () => true) {
	if (!existsSync(dir)) return [];
	const output = [];
	for (const entry of readdirSync(dir)) {
		const path = resolve(dir, entry);
		const stat = statSync(path);
		if (stat.isDirectory()) {
			output.push(...walkFiles(path, predicate));
		} else if (predicate(path)) {
			output.push(path);
		}
	}
	return output;
}

export function lineNumberFor(text, needle) {
	const index = text.indexOf(needle);
	if (index < 0) return 0;
	return text.slice(0, index).split(/\r?\n/).length;
}

export async function runChecks(checks) {
	const results = [];
	for (const check of checks) {
		try {
			await check.run();
			results.push({ name: check.name, status: 'passed', message: check.message ?? 'passed' });
		} catch (error) {
			results.push({ name: check.name, status: 'failed', message: error instanceof Error ? error.message : String(error) });
		}
	}
	return results;
}

export function summarize(results) {
	return {
		passed: results.filter((result) => result.status === 'passed').length,
		failed: results.filter((result) => result.status === 'failed').length,
		results,
	};
}

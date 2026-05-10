#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';

const command = process.argv[2];
const args = process.argv.slice(3);
const inDocker = existsSync('/.dockerenv') || process.env.TRACK_BINOCLE_IN_DOCKER === '1';

if (!inDocker) {
	console.error('This project runs through Docker only. Use `docker compose up -d --build` from the repository root.');
	process.exit(1);
}

if (!command) {
	console.error('No container command was provided.');
	process.exit(2);
}

const child = spawn(command, args, {
	stdio: 'inherit',
	env: {
		...process.env,
		PATH: `${process.cwd()}/node_modules/.bin:${process.env.PATH ?? ''}`,
		TRACK_BINOCLE_IN_DOCKER: '1',
	},
});

child.on('error', (error) => {
	console.error(error.message);
	process.exit(1);
});

child.on('exit', (code, signal) => {
	if (signal) {
		process.kill(process.pid, signal);
		return;
	}
	process.exit(code ?? 0);
});

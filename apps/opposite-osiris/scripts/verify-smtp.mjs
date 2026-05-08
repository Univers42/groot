#!/usr/bin/env node
import assert from 'node:assert/strict';
import tls from 'node:tls';

const config = {
	host: process.env.SMTP_HOST ?? 'smtp.titan.email',
	port: Number(process.env.SMTP_PORT ?? '465'),
	encryption: process.env.SMTP_ENCRYPTION ?? 'SSL',
	username: process.env.SMTP_USERNAME ?? '',
	password: process.env.SMTP_PASSWORD ?? '',
	fromName: process.env.SMTP_FROM_NAME ?? 'Prismatica',
	fromAddress: process.env.SMTP_FROM_ADDRESS ?? process.env.SMTP_USERNAME ?? '',
	toAddress: process.env.SMTP_TEST_TO ?? 'dev.pro.photo@gmail.com',
};

function requireConfig() {
	assert.ok(config.host, 'SMTP_HOST is required.');
	assert.ok(Number.isInteger(config.port) && config.port > 0, 'SMTP_PORT must be a positive integer.');
	assert.ok(config.username, 'SMTP_USERNAME is required.');
	assert.ok(config.password, 'SMTP_PASSWORD is required.');
	assert.ok(config.fromAddress, 'SMTP_FROM_ADDRESS is required.');
}

function createSmtpClient() {
	const socket = tls.connect({ host: config.host, port: config.port, servername: config.host, rejectUnauthorized: true });
	socket.setEncoding('utf8');
	let buffer = '';
	const lines = [];
	const waiters = [];

	const flushWaiters = () => {
		while (lines.length > 0 && waiters.length > 0) {
			const waiter = waiters.shift();
			waiter.resolve(lines.shift());
		}
	};

	socket.on('data', (chunk) => {
		buffer += chunk;
		let index = buffer.indexOf('\n');
		while (index >= 0) {
			const line = buffer.slice(0, index).replace(/\r$/, '');
			buffer = buffer.slice(index + 1);
			lines.push(line);
			index = buffer.indexOf('\n');
		}
		flushWaiters();
	});

	const readLine = (timeoutMs = 10000) => new Promise((resolve, reject) => {
		if (lines.length > 0) {
			resolve(lines.shift());
			return;
		}
		const timer = setTimeout(() => reject(new Error('SMTP read timed out.')), timeoutMs);
		waiters.push({
			resolve: (line) => {
				clearTimeout(timer);
				resolve(line);
			},
			reject,
		});
	});

	const readResponse = async () => {
		const responseLines = [];
		let code = '';
		for (;;) {
			const line = await readLine();
			responseLines.push(line);
			if (!code) {
				code = line.slice(0, 3);
			}
			if (/^\d{3} /.test(line)) {
				return { code: Number(code), text: responseLines.join('\n') };
			}
		}
	};

	const send = async (line, expectedCodes) => {
		socket.write(`${line}\r\n`);
		const response = await readResponse();
		if (!expectedCodes.includes(response.code)) {
			throw new Error(`SMTP command failed. Expected ${expectedCodes.join('/')} but received:\n${response.text}`);
		}
		return response;
	};

	return { socket, readResponse, send };
}

function mailBody() {
	const timestamp = new Date().toISOString();
	return [
		`From: ${config.fromName} <${config.fromAddress}>`,
		`To: ${config.toAddress}`,
		'Subject: Prismatica SMTP test',
		'MIME-Version: 1.0',
		'Content-Type: text/plain; charset=UTF-8',
		'',
		`Prismatica SMTP test sent at ${timestamp}.`,
		'This message verifies the Titan SMTP runtime configuration.',
	].join('\r\n');
}

try {
	requireConfig();
	console.log(`Connecting to ${config.host}:${config.port} (${config.encryption}) as ${config.username}; password=[REDACTED]`);
	const client = createSmtpClient();
	try {
		await new Promise((resolve, reject) => {
			client.socket.once('secureConnect', resolve);
			client.socket.once('error', reject);
		});
		const greeting = await client.readResponse();
		assert.equal(greeting.code, 220, `Unexpected SMTP greeting:\n${greeting.text}`);
		await client.send('EHLO prismatica.local', [250]);
		await client.send('AUTH LOGIN', [334]);
		await client.send(Buffer.from(config.username, 'utf8').toString('base64'), [334]);
		await client.send(Buffer.from(config.password, 'utf8').toString('base64'), [235]);
		await client.send(`MAIL FROM:<${config.fromAddress}>`, [250]);
		await client.send(`RCPT TO:<${config.toAddress}>`, [250, 251]);
		await client.send('DATA', [354]);
		const dataResponse = await client.send(`${mailBody()}\r\n.`, [250]);
		console.log(`SMTP send accepted by server:\n${dataResponse.text}`);
		await client.send('QUIT', [221]).catch(() => undefined);
		client.socket.end();
	} catch (error) {
		client.socket.destroy();
		throw error;
	}
} catch (error) {
	console.error(error instanceof Error ? error.message : String(error));
	process.exitCode = 1;
}

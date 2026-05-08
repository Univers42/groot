#!/usr/bin/env node
import http from 'node:http';
import https from 'node:https';
import { assert, baasHeaders, config, fetchWithTimeout, passed, restUrl, runChecks } from './_shared.mjs';

function rawRequestWithHugeContentLength(timeoutMs = 2000) {
	return new Promise((resolve) => {
		const target = new URL(restUrl('/users'));
		const client = target.protocol === 'https:' ? https : http;
		const request = client.request({
			protocol: target.protocol,
			hostname: target.hostname,
			port: target.port,
			path: target.pathname + target.search,
			method: 'POST',
			headers: {
				apikey: config.anonKey,
				Authorization: `Bearer ${config.anonKey}`,
				Accept: 'application/json',
				'Content-Type': 'application/json',
				'Content-Length': '104857600',
			},
		}, (response) => {
			response.resume();
			response.on('end', () => resolve({ status: response.statusCode ?? 0, timedOut: false, closed: false }));
		});
		request.setTimeout(timeoutMs, () => {
			request.destroy(new Error('timeout'));
			resolve({ status: 0, timedOut: true, closed: false });
		});
		request.on('error', (error) => {
			resolve({ status: 0, timedOut: false, closed: error.code === 'ECONNRESET' || error.message === 'socket hang up' });
		});
		request.end();
	});
}

export async function run() {
	return await runChecks([
		{
			name: 'parallel REST requests remain bounded',
			description: 'Checks 50 parallel reads do not crash the gateway; 429 is acceptable under load.',
			run: async () => {
				const requests = Array.from({ length: 50 }, () => fetchWithTimeout(restUrl('/users?select=id&limit=1'), { headers: baasHeaders() }, 5000));
				const settled = await Promise.allSettled(requests);
				assert.equal(settled.length, 50);
				for (const result of settled) {
					assert.equal(result.status, 'fulfilled', `parallel request rejected: ${result.reason}`);
					assert.ok([200, 204, 400, 401, 403, 404, 429].includes(result.value.status), `unexpected load response HTTP ${result.value.status}`);
				}
				return passed('Gateway responded to all 50 parallel REST requests.');
			},
		},
		{
			name: 'huge content-length rejected or closed',
			description: 'Checks a request claiming a 100 MB body is rejected or closed without hanging.',
			run: async () => {
				const result = await rawRequestWithHugeContentLength();
				assert.equal(result.timedOut, false, 'huge Content-Length request hung until timeout');
				assert.ok(result.closed || [400, 401, 403, 404, 408, 411, 413, 417, 429].includes(result.status), `huge Content-Length returned unexpected HTTP ${result.status}`);
				return passed('Huge Content-Length request did not hang.');
			},
		},
		{
			name: 'many headers handled quickly',
			description: 'Checks a request with 200 custom headers receives a timely response instead of exhausting the gateway.',
			run: async () => {
				const headers = baasHeaders();
				for (let index = 0; index < 200; index += 1) {
					headers[`x-security-test-${index}`] = `value-${index}`;
				}
				const response = await fetchWithTimeout(restUrl('/users?select=id&limit=1'), { headers }, 2000);
				assert.ok([200, 204, 400, 401, 403, 404, 429, 431].includes(response.status), `many-header request returned unexpected HTTP ${response.status}`);
				return passed('Gateway responded to the many-header request within 2 seconds.');
			},
		},
	]);
}

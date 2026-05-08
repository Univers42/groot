#!/usr/bin/env node
import { assert, baasHeaders, fetchWithTimeout, passed, runChecks, skipped, storageUrl, textBody } from './_shared.mjs';

const traversalPaths = ['/object/../../etc/passwd', '/object/%2e%2e%2fetc%2fpasswd'];

export async function run() {
	return await runChecks([
		{
			name: 'storage path traversal blocked',
			description: 'Checks object storage paths cannot traverse outside buckets or read host files.',
			run: async () => {
				let skippedCount = 0;
				for (const path of traversalPaths) {
					const response = await fetchWithTimeout(storageUrl(path), { headers: baasHeaders() });
					const body = await textBody(response);
					assert.ok(!body.includes('root:x:0:0:'), `path traversal read file contents for ${path}`);
					if ([404, 503].includes(response.status)) {
						skippedCount += 1;
						continue;
					}
					assert.ok([400, 401, 403].includes(response.status), `path traversal ${path} returned unexpected HTTP ${response.status}`);
				}

				if (skippedCount === traversalPaths.length) {
					return skipped('Storage service is disabled or unrouted in this profile; traversal checks returned 404/503.');
				}

				return passed('Storage traversal attempts were rejected.');
			},
		},
	]);
}

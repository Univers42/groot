#!/usr/bin/env node

console.log('[bootstrap] Generating BaaS and website runtime environment...');
await import('./bootstrap-env.mjs');

console.log('[bootstrap] Ensuring osionos bridge runtime secrets...');
await import('./ensure-osionos-runtime-secrets.mjs');

console.log('[bootstrap] Runtime environment is ready. Next: docker compose up -d --build');

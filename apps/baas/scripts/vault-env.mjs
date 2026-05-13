#!/usr/bin/env node
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '../../..');
const command = process.argv[2] ?? 'help';
const vaultAddr = process.env.VAULT_ADDR ?? 'http://127.0.0.1:8200';
const vaultKeysFile = process.env.VAULT_KEYS_FILE ?? '/vault/data/.vault-keys.json';
const kvPrefix = process.env.VAULT_ENV_PREFIX ?? 'secret/data/track-binocle/env';
const vaultPolicyDir = resolve(repoRoot, 'apps/baas/mini-baas-infra/docker/services/vault/policies');
const categories = ['required', 'recommended', 'optional', 'legacy'];
const serviceAppRoles = [
  'kong',
  'gotrue',
  'postgrest',
  'postgres',
  'db-bootstrap',
  'project-db-init',
  'pg-meta',
  'supavisor',
  'osionos-bridge',
  'osionos-app',
  'auth-gateway',
  'opposite-osiris',
  'mail',
  'mail-bridge',
  'calendar',
  'calendar-bridge',
];
const teamPolicies = [
  { role: 'reader', name: 'track-binocle-env-reader', file: 'track-binocle-env-reader.hcl' },
  { role: 'writer', name: 'track-binocle-env-writer', file: 'track-binocle-env-writer.hcl' },
];

const managedFiles = [
  {
    id: 'root',
    title: 'Root osionos bridge runtime',
    envPath: '.env.local',
    examplePath: '.env.example',
    required: ['OSIONOS_BRIDGE_SHARED_SECRET', 'OSIONOS_APP_SESSION_SECRET', 'OSIONOS_BRIDGE_EMAIL_HASH_SALT', 'OSIONOS_APP_URL', 'OSIONOS_ALLOWED_ORIGIN'],
    recommended: ['PUBLIC_OSIONOS_APP_URL'],
    optional: ['SONAR_TOK'],
  },
  {
    id: 'opposite-osiris',
    title: 'opposite-osiris website and auth gateway',
    envPath: 'apps/opposite-osiris/.env.local',
    examplePath: 'apps/opposite-osiris/.env.example',
    required: ['PUBLIC_BAAS_URL', 'PUBLIC_AUTH_GATEWAY_URL', 'PUBLIC_BAAS_ANON_KEY', 'PUBLIC_SITE_URL', 'PUBLIC_OSIONOS_APP_URL', 'ASTRO_DEV_HOST', 'ASTRO_DEV_PORT'],
    recommended: ['AUTH_REQUIRE_EMAIL_VERIFICATION', 'PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION', 'GOTRUE_MAILER_AUTOCONFIRM', 'TURNSTILE_BYPASS_LOCAL'],
    optional: ['ASTRO_DEV_HTTPS', 'ASTRO_DEV_HTTPS_CERT', 'ASTRO_DEV_HTTPS_KEY'],
    legacy: ['NEXT_PUBLIC_BAAS_URL', 'NEXT_PUBLIC_BAAS_ANON_KEY'],
  },
  {
    id: 'osionos-app',
    title: 'osionos app and bridge API',
    envPath: 'apps/osionos/app/.env',
    examplePath: 'apps/osionos/app/.env.example',
    required: ['VITE_API_URL', 'VITE_REQUIRE_BRIDGE_SESSION', 'VITE_PRISMATICA_URL'],
    recommended: ['VITE_PORT', 'OSIONOS_BRIDGE_PORT', 'OSIONOS_APP_URL', 'OSIONOS_ALLOWED_ORIGIN', 'OSIONOS_BRIDGE_PERSISTENCE', 'OSIONOS_BRIDGE_REQUIRE_BAAS', 'OSIONOS_BAAS_URL'],
    optional: ['UNSPLASH_ACCESS_KEY', 'SONAR_PORT', 'DOCKER_USER', 'DOCKER_PAT', 'GITHUB_USER', 'GITHUB_PAT'],
  },
  {
    id: 'mail',
    title: 'osionos Mail and Gmail bridge runtime',
    envPath: 'apps/mail/.env.local',
    examplePath: 'apps/mail/.env.example',
    fallbackEnvPaths: ['apps/mail/.env'],
    required: ['GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET'],
    recommended: ['MAIL_BRIDGE_PORT', 'MAIL_APP_ORIGIN', 'MAIL_BRIDGE_PUBLIC_ORIGIN', 'GMAIL_REDIRECT_URI', 'GMAIL_SYNC_LIMIT', 'GMAIL_MAX_SYNC_LIMIT', 'GMAIL_LIST_PAGE_SIZE', 'GMAIL_DETAIL_BATCH_SIZE', 'VITE_GMAIL_SYNC_LIMIT', 'VITE_GMAIL_SYNC_PAGE_SIZE'],
    optional: ['GMAIL_CALLBACK_PATHS', 'MAIL_BRIDGE_VAULT_ENABLED', 'VAULT_ADDR', 'MAIL_BRIDGE_VAULT_OAUTH_PATH', 'VAULT_TOKEN', 'VAULT_ROLE_ID', 'VAULT_SECRET_ID'],
  },
  {
    id: 'calendar',
    title: 'osionos Calendar and Google Calendar bridge runtime',
    envPath: 'apps/calendar/.env.local',
    examplePath: 'apps/calendar/.env.example',
    fallbackEnvPaths: ['apps/calendar/.env', 'apps/mail/.env', 'apps/baas/.env.local'],
    required: ['GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET'],
    recommended: ['CALENDAR_BRIDGE_PORT', 'CALENDAR_APP_ORIGIN', 'CALENDAR_BRIDGE_PUBLIC_ORIGIN', 'CALENDAR_REDIRECT_URI', 'CALENDAR_BAAS_URL', 'CALENDAR_BAAS_PUBLIC_URL', 'CALENDAR_BRIDGE_REQUIRE_BAAS', 'CALENDAR_EVENTS_PAGE_SIZE', 'VITE_CALENDAR_BRIDGE_URL', 'VITE_CALENDAR_BAAS_URL'],
    optional: ['CALENDAR_CALLBACK_PATHS', 'CALENDAR_BAAS_SERVICE_KEY', 'CALENDAR_BRIDGE_VAULT_ENABLED', 'CALENDAR_BRIDGE_VAULT_OAUTH_PATH', 'VAULT_ADDR', 'VAULT_TOKEN', 'VAULT_ROLE_ID', 'VAULT_SECRET_ID'],
  },
  {
    id: 'baas',
    title: 'Root mini-BaaS runtime',
    envPath: 'apps/baas/.env.local',
    examplePath: 'apps/baas/.env.example',
    required: ['POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB', 'DATABASE_URL', 'PGRST_DB_URI', 'PGRST_DB_ANON_ROLE', 'JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY', 'KONG_PUBLIC_API_KEY', 'KONG_SERVICE_API_KEY', 'KONG_ANON_UUID', 'GOTRUE_DB_DATABASE_URL', 'GOTRUE_JWT_SECRET', 'PGRST_JWT_SECRET', 'PG_META_DB_HOST', 'PG_META_DB_PORT', 'PG_META_DB_NAME', 'PG_META_DB_USER', 'PG_META_DB_PASSWORD', 'SECRET_KEY_BASE', 'VAULT_ENC_KEY'],
    recommended: ['PROJECT_INIT_MARKER', 'GOTRUE_SITE_URL', 'GOTRUE_URI_ALLOW_LIST'],
  },
  {
    id: 'mini-baas-infra',
    title: 'Standalone mini-baas-infra runtime',
    envPath: 'apps/baas/mini-baas-infra/.env',
    examplePath: 'apps/baas/mini-baas-infra/.env.example',
    fallbackEnvPaths: ['apps/baas/.env.local'],
    required: ['POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB', 'DATABASE_URL', 'PGRST_DB_URI', 'PGRST_DB_ANON_ROLE', 'PGRST_DB_SCHEMA', 'JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY', 'KONG_PUBLIC_API_KEY', 'KONG_SERVICE_API_KEY'],
    recommended: ['API_EXTERNAL_URL', 'PUBLIC_SITE_URL', 'GOTRUE_SITE_URL', 'GOTRUE_URI_ALLOW_LIST', 'KONG_CORS_ORIGIN_APP', 'KONG_CORS_ORIGIN_FRONTEND', 'KONG_CORS_ORIGIN_PLAYGROUND', 'KONG_CORS_ORIGIN_STUDIO'],
  },
  {
    id: 'notion-database-sys',
    title: 'Notion database system example runtime',
    examplePath: 'apps/osionos/app/src/shared/notion-database-sys/.env.example',
    required: ['ACTIVE_DB_SOURCE', 'API_HOST', 'API_PORT'],
    recommended: ['DATABASE_URL', 'POSTGRES_HOST', 'POSTGRES_PORT', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB', 'MONGO_URI', 'MONGO_HOST', 'MONGO_PORT', 'MONGO_USER', 'MONGO_PASSWORD', 'MONGO_DB'],
  },
];

const optionalPatterns = [
  /^SMTP_/, /^GOTRUE_SMTP_/, /^TURNSTILE_/, /^PUBLIC_TURNSTILE_/, /^GOOGLE_/, /^GITHUB_/, /^FORTYTWO_/, /^GMAIL_/, /^MAIL_/, /^CALENDAR_/, /^LLM_/, /^SONAR/, /^UNSPLASH_/, /^DOCKER_/, /^MINIO_/, /^MONGO_/, /^AI_/, /^ANALYTICS_/, /^GDPR_/, /^NEWSLETTER_/, /^LOG_/, /^RUST_LOG$/, /^WAF_/, /^STUDIO_/, /^SUPABASE_/, /^SESSION_/, /^CSV_/, /^JSON_/, /^REDIS_/, /^PLAYGROUND_/, /^SRC_/, /^SYNC_/, /^CONTRACT_/, /^ADAPTER_REGISTRY_/, /^QUERY_/, /^STORAGE_/, /^PERMISSION_/, /^SCHEMA_/, /^VITE_BAAS_/, /^VITE_ALLOW_OFFLINE_MODE$/,
];

const secretPatterns = [/SECRET/, /TOKEN/, /PASSWORD/, /PASS$/, /_KEY$/, /PAT$/, /JWT/];

const examples = {
  ACTIVE_DB_SOURCE: 'json',
  API_EXTERNAL_URL: 'http://localhost:8000/auth/v1',
  API_HOST: '0.0.0.0',
  API_PORT: '3000',
  APP_PORT: '3001',
  ASTRO_DEV_HOST: '0.0.0.0',
  ASTRO_DEV_HTTPS: 'false',
  ASTRO_DEV_HTTPS_CERT: '',
  ASTRO_DEV_HTTPS_KEY: '',
  ASTRO_DEV_PORT: '4322',
  AUTH_REQUIRE_EMAIL_VERIFICATION: 'false',
  CALENDAR_APP_ORIGIN: 'http://localhost:3003',
  CALENDAR_BAAS_PUBLIC_URL: 'http://localhost:8000',
  CALENDAR_BAAS_SERVICE_KEY: '',
  CALENDAR_BAAS_URL: 'http://localhost:8000',
  CALENDAR_BRIDGE_PORT: '4200',
  CALENDAR_BRIDGE_PUBLIC_ORIGIN: 'http://localhost:4200',
  CALENDAR_BRIDGE_REQUIRE_BAAS: 'false',
  CALENDAR_BRIDGE_VAULT_ENABLED: 'false',
  CALENDAR_BRIDGE_VAULT_OAUTH_PATH: 'secret/data/mini-baas/oauth',
  CALENDAR_CALLBACK_PATHS: '',
  CALENDAR_EVENTS_PAGE_SIZE: '2500',
  CALENDAR_REDIRECT_URI: 'http://localhost:4200/auth/google/callback',
  DATABASE_URL: 'postgres://postgres:replace-with-postgres-secret@postgres:5432/postgres',
  GMAIL_CALLBACK_PATHS: '',
  GMAIL_DETAIL_BATCH_SIZE: '20',
  GMAIL_LIST_PAGE_SIZE: '500',
  GMAIL_MAX_SYNC_LIMIT: '5000',
  GMAIL_REDIRECT_URI: 'http://localhost:4100/auth/gmail/callback',
  GMAIL_SYNC_LIMIT: '2000',
  GOOGLE_CLIENT_ID: '',
  GOOGLE_CLIENT_SECRET: '',
  GOTRUE_DB_DATABASE_URL: 'postgres://postgres:replace-with-postgres-secret@postgres:5432/postgres',
  GOTRUE_JWT_SECRET: 'replace-with-jwt-secret',
  GOTRUE_MAILER_AUTOCONFIRM: 'true',
  GOTRUE_SITE_URL: 'http://localhost:4322',
  GOTRUE_SMTP_ADMIN_EMAIL: 'noreply@mini-baas.local',
  GOTRUE_SMTP_HOST: 'mailpit',
  GOTRUE_SMTP_PORT: '1025',
  GOTRUE_SMTP_SENDER_NAME: 'opposite-osiris',
  GOTRUE_SMTP_USER: '',
  GOTRUE_SMTP_PASS: '',
  GOTRUE_URI_ALLOW_LIST: 'http://localhost:4322/**,http://localhost:3001/**',
  KONG_ANON_UUID: 'cd4f782c-ac87-5081-b322-b54834d15651',
  KONG_CORS_ORIGIN_APP: 'http://localhost:3000',
  KONG_CORS_ORIGIN_FRONTEND: 'http://localhost:4322',
  KONG_CORS_ORIGIN_PLAYGROUND: 'http://localhost:3100',
  KONG_CORS_ORIGIN_STUDIO: 'http://localhost:3001',
  MAIL_APP_ORIGIN: 'http://localhost:3002',
  MAIL_BRIDGE_PORT: '4100',
  MAIL_BRIDGE_PUBLIC_ORIGIN: 'http://localhost:4100',
  MAIL_BRIDGE_VAULT_ENABLED: 'false',
  MAIL_BRIDGE_VAULT_OAUTH_PATH: 'secret/data/mini-baas/oauth',
  NEXT_PUBLIC_BAAS_URL: '/api',
  OSIONOS_ALLOWED_ORIGIN: 'http://localhost:3001',
  OSIONOS_APP_URL: 'http://localhost:3001',
  OSIONOS_BAAS_URL: 'http://kong:8000',
  OSIONOS_BRIDGE_PERSISTENCE: 'auto',
  OSIONOS_BRIDGE_PORT: '4000',
  OSIONOS_BRIDGE_REQUIRE_BAAS: 'false',
  OSIONOS_BRIDGE_URL: 'http://localhost:4000/api/auth/bridge/session',
  PG_META_DB_HOST: 'postgres',
  PG_META_DB_NAME: 'postgres',
  PG_META_DB_PORT: '5432',
  PG_META_DB_USER: 'postgres',
  PGRST_DB_ANON_ROLE: 'anon',
  PGRST_DB_SCHEMA: 'public',
  PGRST_DB_SCHEMAS: 'public',
  PGRST_DB_URI: 'postgres://postgres:replace-with-postgres-secret@postgres:5432/postgres',
  PGRST_JWT_SECRET: 'replace-with-jwt-secret',
  POSTGRES_DB: 'postgres',
  POSTGRES_HOST: 'postgres',
  POSTGRES_PORT: '5432',
  POSTGRES_USER: 'postgres',
  PROJECT_INIT_MARKER: 'track_binocle_20260504',
  PUBLIC_AUTH_GATEWAY_URL: '/api/auth',
  PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION: 'false',
  PUBLIC_BAAS_URL: '/api',
  PUBLIC_OSIONOS_APP_URL: 'http://localhost:3001',
  PUBLIC_PORTAL_URL: 'http://localhost:4322',
  PUBLIC_SITE_URL: 'http://localhost:4322',
  SMTP_ENCRYPTION: 'none',
  SMTP_FROM_ADDRESS: 'noreply@mini-baas.local',
  SMTP_FROM_NAME: 'opposite-osiris',
  SMTP_HOST: 'mailpit',
  SMTP_PORT: '1025',
  SMTP_SECURE: 'false',
  TURNSTILE_BYPASS_LOCAL: 'true',
  VAULT_ADDR: 'http://vault:8200',
  VAULT_ENV_PREFIX: 'secret/data/track-binocle/env',
  VAULT_ROLE_ID: '',
  VAULT_SECRET_ID: '',
  VAULT_TOKEN: '',
  VITE_API_URL: 'http://localhost:4000',
  VITE_BAAS_ENABLED: 'false',
  VITE_CALENDAR_BAAS_URL: 'http://localhost:8000',
  VITE_CALENDAR_BRIDGE_URL: 'http://localhost:4200',
  VITE_GMAIL_SYNC_LIMIT: '2000',
  VITE_GMAIL_SYNC_PAGE_SIZE: '100',
  VITE_PORT: '3001',
  VITE_PRISMATICA_URL: 'http://localhost:4322',
  VITE_REQUIRE_BRIDGE_SESSION: 'true',
};

const descriptions = {
  ANON_KEY: 'Public anon JWT used by browser and gateway calls.',
  DATABASE_URL: 'Internal Postgres URL used by BaaS services.',
  JWT_SECRET: 'Signing secret shared by GoTrue, PostgREST, Kong, and generated JWTs.',
  GOOGLE_CLIENT_ID: 'Google OAuth client ID used by Mail and Calendar bridges.',
  GOOGLE_CLIENT_SECRET: 'Google OAuth client secret used by Mail and Calendar bridges.',
  KONG_PUBLIC_API_KEY: 'Public API key injected into Kong routing configuration.',
  KONG_SERVICE_API_KEY: 'Privileged service key injected into Kong routing configuration.',
  MAIL_BRIDGE_VAULT_ENABLED: 'Enable Mail bridge OAuth credential loading from Vault.',
  CALENDAR_BRIDGE_VAULT_ENABLED: 'Enable Calendar bridge OAuth credential loading from Vault.',
  OSIONOS_BRIDGE_SHARED_SECRET: 'Shared secret used by the website auth gateway to request osionos bridge tokens.',
  OSIONOS_APP_SESSION_SECRET: 'Secret used by osionos to sign local app sessions.',
  OSIONOS_BRIDGE_EMAIL_HASH_SALT: 'Salt used to hash bridged email identities before persistence.',
  OSIONOS_APP_URL: 'Browser-facing osionos app URL used in bridge redirects.',
  OSIONOS_ALLOWED_ORIGIN: 'Origin accepted by the osionos bridge API.',
  PGRST_DB_URI: 'PostgREST database connection string.',
  SERVICE_ROLE_KEY: 'Privileged JWT used by trusted server-side components only.',
  VAULT_ROLE_ID: 'Vault AppRole role ID for services or invited collaborators.',
  VAULT_SECRET_ID: 'Vault AppRole secret ID for services or invited collaborators.',
  VAULT_TOKEN: 'Short-lived Vault token for fetching or publishing managed environment data.',
  VAULT_ENC_KEY: 'Local encryption material used by Vault-backed BaaS helpers.',
};

function absolute(relativePath) {
  return resolve(repoRoot, relativePath);
}

function parseEnv(filePath) {
  const values = new Map();
  if (!filePath || !existsSync(filePath)) return values;
  for (const rawLine of readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const match = /^\s*(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(.*)$/.exec(rawLine);
    if (!match) continue;
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    values.set(match[1], value);
  }
  return values;
}

function isSecretKey(key) {
  return secretPatterns.some((pattern) => pattern.test(key));
}

function listKeys(config) {
  const keys = new Set();
  for (const key of config.required ?? []) keys.add(key);
  for (const key of config.recommended ?? []) keys.add(key);
  for (const key of config.optional ?? []) keys.add(key);
  for (const key of config.legacy ?? []) keys.add(key);
  for (const pathValue of [config.envPath, config.examplePath]) {
    if (!pathValue) continue;
    for (const key of parseEnv(absolute(pathValue)).keys()) keys.add(key);
  }
  return [...keys].sort((left, right) => left.localeCompare(right));
}

function categoryFor(config, key) {
  for (const category of categories) {
    if ((config[category] ?? []).includes(key)) return category;
  }
  if (key.startsWith('NEXT_PUBLIC_')) return 'legacy';
  if (optionalPatterns.some((pattern) => pattern.test(key))) return 'optional';
  if (/URL$|URI$|HOST$|PORT$|ORIGIN|SITE/.test(key)) return 'recommended';
  return 'required';
}

function generatedDescription(key) {
  if (descriptions[key]) return descriptions[key];
  if (key.startsWith('PUBLIC_') || key.startsWith('VITE_') || key.startsWith('NEXT_PUBLIC_')) return 'Browser-exposed configuration. Never put private secrets in this key.';
  if (key.startsWith('SMTP_') || key.startsWith('GOTRUE_SMTP_')) return 'SMTP setting used when local email delivery is enabled.';
  if (key.startsWith('TURNSTILE_') || key.startsWith('PUBLIC_TURNSTILE_')) return 'Cloudflare Turnstile anti-abuse setting.';
  if (key.startsWith('KONG_CORS_')) return 'Allowed CORS origin for Kong gateway responses.';
  if (key.startsWith('POSTGRES_') || key.startsWith('PG_META_')) return 'Postgres connection setting for the local Docker database.';
  if (key.startsWith('PGRST_')) return 'PostgREST configuration consumed by the BaaS gateway.';
  if (key.startsWith('GOTRUE_')) return 'GoTrue authentication service configuration.';
  if (key.startsWith('OSIONOS_')) return 'osionos bridge/runtime setting.';
  if (key.startsWith('MONGO_')) return 'MongoDB setting used by optional document/database adapters.';
  if (key.startsWith('LLM_')) return 'Optional model provider setting for AI features.';
  if (key.includes('PORT')) return 'Local port for Docker or development tooling.';
  if (key.includes('URL') || key.includes('URI')) return 'Service URL used for local routing.';
  if (isSecretKey(key)) return 'Secret or token used for local authentication.';
  return 'Runtime configuration key for this service.';
}

function categoryComment(category) {
  if (category === 'required') return 'Required. The service will not boot, authenticate, or bridge correctly without these keys.';
  if (category === 'recommended') return 'Recommended. Defaults keep local Docker usable, but set these to make routing, email, and integrations explicit.';
  if (category === 'optional') return 'Optional. Leave empty to disable the integration and gain a smaller local attack surface.';
  return 'Legacy or compatibility. Keep only while older scripts or clients still reference these names.';
}

function commentForKey(key, category) {
  const prefixes = {
    required: 'Required',
    recommended: 'Recommended',
    optional: 'Optional',
    legacy: 'Compatibility',
  };
  const fallbacks = {
    required: 'If omitted: startup, auth, or bridge flow can fail.',
    recommended: 'If omitted: Docker defaults are used, which is fine for local dev but less explicit for the team.',
    optional: 'If omitted: the related integration is disabled, reducing local secret sprawl.',
    legacy: 'If omitted: modern code should keep working once no legacy references remain.',
  };
  const prefix = prefixes[category] ?? prefixes.legacy;
  const fallback = fallbacks[category] ?? fallbacks.legacy;
  return `${prefix}. ${generatedDescription(key)} ${fallback}`;
}

function exampleFor(key, category) {
  if (examples[key] !== undefined) return examples[key];
  if (isSecretKey(key)) return category === 'optional' ? '' : `replace-with-${key.toLowerCase().replaceAll('_', '-')}`;
  if (key.endsWith('_PORT') || key === 'PORT') return '3000';
  if (key.endsWith('_HOST')) return 'localhost';
  if (key.endsWith('_URL')) return 'http://localhost:3000';
  if (key.endsWith('_URI')) return 'postgres://postgres:replace-with-postgres-secret@postgres:5432/postgres';
  if (/^(ENABLE|REQUIRE|ALLOW|SYNC|.*_ENABLED)$/.test(key)) return 'false';
  if (category === 'optional') return '';
  return `replace-with-${key.toLowerCase().replaceAll('_', '-')}`;
}

function serialize(key, value) {
  if (value === undefined || value === null) return `${key}=`;
  const text = String(value);
  if (text === '') return `${key}=`;
  if (/\s|#/.test(text)) return `${key}=${JSON.stringify(text)}`;
  return `${key}=${text}`;
}

function renderEnv(config, values, { example = false } = {}) {
  const keys = listKeys(config);
  const grouped = new Map(categories.map((category) => [category, []]));
  for (const key of keys) grouped.get(categoryFor(config, key)).push(key);

  const lines = [
    '# -----------------------------------------------------------------------------',
    `# ${config.title}`,
    '# Managed by apps/baas/scripts/vault-env.mjs.',
    example
      ? '# Copy to the matching .env file only for local development; Vault is the source of truth after seeding.'
      : '# Local materialized copy. Values are preserved, but secrets should be seeded to Vault for team use.',
    '# -----------------------------------------------------------------------------',
    '',
  ];

  for (const category of categories) {
    const sectionKeys = grouped.get(category).sort((left, right) => left.localeCompare(right));
    if (sectionKeys.length === 0) continue;
    lines.push(`# ${category.toUpperCase()}: ${categoryComment(category)}`);
    for (const key of sectionKeys) {
      let envLine;
      if (example) {
        envLine = serialize(key, exampleFor(key, category));
      } else if (values.has(key) && values.get(key) !== '') {
        envLine = serialize(key, values.get(key));
      } else {
        envLine = `# ${serialize(key, '')}`;
      }
      lines.push(
        `# ${commentForKey(key, category)}`,
        envLine,
        '',
      );
    }
  }

  return `${lines.join('\n').replace(/\n+$/, '')}\n`;
}

function writeManaged(config, { envValues, writeExample = true }) {
  if (config.envPath) {
    const envFile = absolute(config.envPath);
    mkdirSync(dirname(envFile), { recursive: true });
    writeFileSync(envFile, renderEnv(config, envValues, { example: false }), { mode: 0o600 });
    console.log(`[env] wrote ${config.envPath}`);
  }
  if (writeExample && config.examplePath) {
    const exampleFile = absolute(config.examplePath);
    mkdirSync(dirname(exampleFile), { recursive: true });
    writeFileSync(exampleFile, renderEnv(config, new Map(), { example: true }), { mode: 0o644 });
    console.log(`[env] wrote ${config.examplePath}`);
  }
}

function formatLocal() {
  for (const config of managedFiles) {
    const envValues = parseEnv(config.envPath ? absolute(config.envPath) : '');
    writeManaged(config, { envValues, writeExample: true });
  }
}

function valuesForConfig(config) {
  const values = parseEnv(config.envPath ? absolute(config.envPath) : '');
  for (const fallbackPath of config.fallbackEnvPaths ?? []) {
    for (const [key, value] of parseEnv(absolute(fallbackPath)).entries()) {
      if (!values.get(key)) values.set(key, value);
    }
  }
  if (config.id === 'mini-baas-infra' && !values.get('PGRST_DB_SCHEMA')) values.set('PGRST_DB_SCHEMA', 'public');
  return values;
}

function tokenFromKeysFile() {
  if (process.env.VAULT_TOKEN) return process.env.VAULT_TOKEN;
  if (existsSync(vaultKeysFile)) {
    const keys = JSON.parse(readFileSync(vaultKeysFile, 'utf8'));
    if (keys.root_token) return keys.root_token;
  }
  throw new Error('No VAULT_TOKEN set and no Vault keys file found. Run make vault-up first.');
}

async function vaultRequestAs(method, path, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['X-Vault-Token'] = token;
  const response = await fetch(`${vaultAddr}/v1/${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Vault ${method} ${path} failed with HTTP ${response.status}`);
  if (response.status === 204) return {};
  return response.json();
}

async function vaultRequest(method, path, body) {
  return vaultRequestAs(method, path, body, tokenFromKeysFile());
}

async function ensureKv() {
  const mounts = await vaultRequest('GET', 'sys/mounts');
  if (!mounts?.['secret/']) {
    await vaultRequest('POST', 'sys/mounts/secret', { type: 'kv', options: { version: '2' } });
  }
}

async function ensureKvWhenAllowed() {
  try {
    await ensureKv();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.warn(`[vault] skipped KV mount check; continuing with the existing secret/ mount (${message})`);
  }
}

function envRecord(config) {
  const values = valuesForConfig(config);
  const data = {};
  for (const key of listKeys(config)) data[key] = values.get(key) ?? '';
  return { config, values, data };
}

function missingRequired(config, values) {
  return (config.required ?? []).filter((key) => !values.get(key));
}

function requiredFixHint() {
  return 'Fetch current team secrets with make vault-fetch-shared, or set the listed keys in ignored env files and publish them with make vault-publish or make vault-repair-shared.';
}

function assertRequiredRecords(records, source) {
  const failures = [];
  for (const { config, values } of records) {
    const missing = missingRequired(config, values);
    if (missing.length > 0) failures.push(`${config.envPath}: ${missing.join(', ')}`);
  }
  if (failures.length > 0) {
    throw new Error([
      `${source} is missing required managed env values:`,
      ...failures.map((line) => `- ${line}`),
      requiredFixHint(),
    ].join('\n'));
  }
}

function mergedFetchedValues(config, vaultValues) {
  const localValues = valuesForConfig(config);
  const merged = new Map();
  for (const key of listKeys(config)) {
    const vaultValue = vaultValues[key];
    if (vaultValue !== undefined && vaultValue !== null && String(vaultValue) !== '') {
      merged.set(key, String(vaultValue));
      continue;
    }
    const localValue = localValues.get(key);
    if (localValue) merged.set(key, localValue);
    else if (vaultValue !== undefined && vaultValue !== null) merged.set(key, String(vaultValue));
  }
  return merged;
}

async function seedVault() {
  await ensureKvWhenAllowed();
  const records = managedFiles.filter((item) => item.envPath).map(envRecord);
  assertRequiredRecords(records, 'Local env before Vault publish');
  for (const { config, data } of records) {
    await vaultRequest('POST', `${kvPrefix}/${config.id}`, { data });
    console.log(`[vault] published ${config.id}`);
  }
}

function countValues(values) {
  return Object.values(values).filter((value) => value !== undefined && value !== null && String(value) !== '').length;
}

async function statusVault() {
  const failures = [];
  for (const config of managedFiles.filter((item) => item.envPath)) {
    const keys = listKeys(config);
    const localValues = valuesForConfig(config);
    const payload = await vaultRequest('GET', `${kvPrefix}/${config.id}`);
    const vaultValues = payload?.data?.data ?? {};
    const missingLocalRequired = (config.required ?? []).filter((key) => !localValues.get(key));
    const missingVaultRequired = (config.required ?? []).filter((key) => !vaultValues[key]);
    const localCount = keys.filter((key) => localValues.get(key)).length;
    console.log(`[vault] ${config.id}: local ${localCount}/${keys.length}, vault ${countValues(vaultValues)}/${keys.length}, missing required local=${missingLocalRequired.length}, vault=${missingVaultRequired.length}`);
    if (missingLocalRequired.length > 0) failures.push(`${config.envPath}: missing local ${missingLocalRequired.join(', ')}`);
    if (missingVaultRequired.length > 0) failures.push(`${config.id}: missing Vault ${missingVaultRequired.join(', ')}`);
  }
  if (failures.length > 0) {
    throw new Error([
      'Vault status found missing required managed env values:',
      ...failures.map((line) => `- ${line}`),
      requiredFixHint(),
    ].join('\n'));
  }
}

async function syncTeamPolicies() {
  for (const policy of teamPolicies) {
    const policyPath = resolve(vaultPolicyDir, policy.file);
    const policyText = readFileSync(policyPath, 'utf8');
    await vaultRequest('PUT', `sys/policies/acl/${policy.name}`, { policy: policyText });
    console.log(`[vault] policy ${policy.name} synced`);
  }
}

async function createTeamToken() {
  const role = process.env.VAULT_TEAM_ROLE ?? 'reader';
  const policy = teamPolicies.find((item) => item.role === role);
  if (!policy) throw new Error('VAULT_TEAM_ROLE must be reader or writer');

  await syncTeamPolicies();

  const ttl = process.env.VAULT_TOKEN_TTL ?? (role === 'writer' ? '8h' : '24h');
  const response = await vaultRequest('POST', 'auth/token/create', {
    policies: [policy.name],
    ttl,
    renewable: false,
    metadata: {
      project: 'track-binocle',
      role,
    },
  });
  const clientToken = response?.auth?.client_token;
  if (!clientToken) throw new Error('Vault token creation did not return a client token');

  const tokenFile = absolute(process.env.VAULT_TEAM_TOKEN_FILE ?? `.vault/track-binocle-${role}.env`);
  const publicVaultAddr = process.env.VAULT_PUBLIC_ADDR ?? vaultAddr;
  mkdirSync(dirname(tokenFile), { recursive: true, mode: 0o700 });
  writeFileSync(tokenFile, [
    '# Track Binocle Vault invite token. Keep this file private.',
    serialize('VAULT_ADDR', publicVaultAddr),
    serialize('VAULT_TOKEN', clientToken),
    serialize('VAULT_ENV_PREFIX', kvPrefix),
    '',
  ].join('\n'), { mode: 0o600 });
  const repoPrefix = `${repoRoot}/`;
  const tokenDisplayPath = tokenFile.startsWith(repoPrefix) ? tokenFile.slice(repoPrefix.length) : tokenFile;
  console.log(`[vault] wrote ${tokenDisplayPath} with ${role} policy and ttl ${ttl}`);
}

async function rotateAppRoles() {
  for (const service of serviceAppRoles) {
    await vaultRequest('POST', `auth/approle/role/${service}`, {
      token_policies: 'mini-baas',
      token_ttl: '1h',
      token_max_ttl: '4h',
      secret_id_ttl: '0',
    });

    const rolePayload = await vaultRequest('GET', `auth/approle/role/${service}/role-id`);
    const roleId = rolePayload?.data?.role_id;
    const secretPayload = await vaultRequest('POST', `auth/approle/role/${service}/secret-id`);
    const secretId = secretPayload?.data?.secret_id;
    if (!roleId || !secretId) throw new Error(`Failed to rotate AppRole credentials for ${service}`);

    await vaultRequest('POST', `secret/data/mini-baas/approle/${service}`, {
      data: { role_id: roleId, secret_id: secretId },
    });
    console.log(`[vault] AppRole ${service} rotated`);
  }
}

async function fetchVault() {
  const records = [];
  for (const config of managedFiles.filter((item) => item.envPath)) {
    const payload = await vaultRequest('GET', `${kvPrefix}/${config.id}`);
    if (!payload?.data?.data) throw new Error(`No Vault env data found for ${config.id}. Run make vault-seed first.`);
    const values = mergedFetchedValues(config, payload.data.data);
    records.push({ config, values });
  }
  assertRequiredRecords(records, 'Vault fetch result');
  for (const { config, values } of records) {
    writeManaged(config, { envValues: values, writeExample: false });
    console.log(`[vault] fetched ${config.id}`);
  }
}

async function verifyAppRoles() {
  for (const service of serviceAppRoles) {
    const credentials = await vaultRequest('GET', `secret/data/mini-baas/approle/${service}`);
    const roleId = credentials?.data?.data?.role_id;
    const secretId = credentials?.data?.data?.secret_id;
    if (!roleId || !secretId) throw new Error(`Missing Vault AppRole credentials for ${service}`);

    const login = await vaultRequestAs('POST', 'auth/approle/login', { role_id: roleId, secret_id: secretId });
    const clientToken = login?.auth?.client_token;
    if (!clientToken) throw new Error(`Vault AppRole login failed for ${service}`);

    const payload = await vaultRequestAs('GET', `${kvPrefix}/root`, undefined, clientToken);
    if (!payload?.data?.data) throw new Error(`Vault AppRole read check failed for ${service}`);
    console.log(`[vault] AppRole ${service} read-check ok`);
  }
}

function backupEnvFiles() {
  for (const config of managedFiles.filter((item) => item.envPath)) {
    const file = absolute(config.envPath);
    if (!existsSync(file)) continue;
    copyFileSync(file, `${file}.bak`);
    console.log(`[env] backup ${config.envPath}.bak`);
  }
}

function removeEnvFiles() {
  for (const config of managedFiles.filter((item) => item.envPath)) {
    const file = absolute(config.envPath);
    if (existsSync(file)) rmSync(file);
  }
}

function verifyRequiredKeys() {
  const records = managedFiles.filter((item) => item.envPath).map((config) => ({ config, values: valuesForConfig(config) }));
  assertRequiredRecords(records, 'Local env validation');
  console.log('[env] required keys restored from Vault');
}

async function roundtrip() {
  backupEnvFiles();
  removeEnvFiles();
  await fetchVault();
  verifyRequiredKeys();
}

if (command === 'format') {
  formatLocal();
} else if (command === 'seed') {
  await seedVault();
} else if (command === 'publish') {
  await seedVault();
} else if (command === 'fetch') {
  await fetchVault();
} else if (command === 'status') {
  await statusVault();
} else if (command === 'validate') {
  verifyRequiredKeys();
} else if (command === 'sync-policies') {
  await syncTeamPolicies();
} else if (command === 'team-token') {
  await createTeamToken();
} else if (command === 'rotate-approles') {
  await rotateAppRoles();
} else if (command === 'backup') {
  backupEnvFiles();
} else if (command === 'roundtrip') {
  await roundtrip();
} else if (command === 'verify-approles') {
  await verifyAppRoles();
} else {
  console.log('Usage: node apps/baas/scripts/vault-env.mjs <format|seed|publish|fetch|status|validate|backup|roundtrip|sync-policies|team-token|rotate-approles|verify-approles>');
}
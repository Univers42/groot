/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   types.ts                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

export type { AuthSession, User } from './core/session.js';

export interface SignInWithPasswordInput {
  email: string;
  password: string;
}

export interface SignUpInput {
  email: string;
  password: string;
  data?: Record<string, unknown>;
}

export interface RecoverInput {
  email: string;
}

export interface VerifyInput {
  type: 'signup' | 'recovery' | 'magiclink' | 'email_change';
  token?: string;
  token_hash?: string;
}

export interface UpdateUserInput {
  email?: string;
  password?: string;
  data?: Record<string, unknown>;
}

export interface AdminCreateUserInput extends SignUpInput {
  email_confirm?: boolean;
  user_metadata?: Record<string, unknown>;
}

export interface AdminUpdateUserInput {
  email?: string;
  password?: string;
  email_confirm?: boolean;
  user_metadata?: Record<string, unknown>;
  app_metadata?: Record<string, unknown>;
}

export interface AdminGenerateLinkInput extends SignUpInput {
  type: 'signup' | 'recovery' | 'magiclink' | 'email_change_current' | 'email_change_new';
  redirect_to?: string;
  data?: Record<string, unknown>;
}

export interface QueryRunInput<TPayload = Record<string, unknown>> {
  databaseId?: string;
  action: string;
  resource: string;
  payload?: TPayload;
}

export interface QueryRunResponse<TResult = unknown> {
  data: TResult;
  count?: number;
  meta?: Record<string, unknown>;
}

export interface ResourceQueryBuilder<Row = Record<string, unknown>> {
  select<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
  insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>): Promise<TResult>;
  update<TResult = Row[]>(values: Partial<Row>, filter?: Record<string, unknown>): Promise<TResult>;
  delete<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
  run<TResult = unknown, TPayload = Record<string, unknown>>(
    action: string,
    payload?: TPayload,
  ): Promise<TResult>;
}

export type RestFilterOperator = 'eq' | 'neq' | 'gt' | 'gte' | 'lt' | 'lte' | 'like' | 'ilike' | 'is';

export interface RestRequestOptions {
  apiKey?: string;
  bearerToken?: string;
  headers?: HeadersInit;
}

export interface RestQueryOptions<Row = Record<string, unknown>> extends RestRequestOptions {
  columns?: string;
  limit?: number;
  offset?: number;
  order?: string;
  filters?: Partial<Record<keyof Row | string, string | number | boolean | null>> | Array<{
    column: keyof Row | string;
    operator: RestFilterOperator;
    value: string | number | boolean | null;
  }>;
}

export interface RestMutationOptions extends RestRequestOptions {
  returning?: 'representation' | 'minimal';
}

export interface RestResourceBuilder<Row = Record<string, unknown>> {
  select<TResult = Row[]>(options?: RestQueryOptions<Row>): Promise<TResult>;
  exists(options?: RestQueryOptions<Row>): Promise<boolean>;
  insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>, options?: RestMutationOptions): Promise<TResult>;
  update<TResult = Row[]>(values: Partial<Row>, options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
  delete<TResult = Row[]>(options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
}

export interface PresignInput {
  bucket: string;
  key: string;
  method?: 'GET' | 'PUT';
  contentType?: string;
}

export interface AnalyticsTrackInput {
  eventType: string;
  data?: Record<string, unknown>;
}

// ── Transactions (POST /query/v1/txn) ────────────────────────────────────────

/** Write operations permitted inside a single-mount atomic batch. */
export type TxnOp = 'insert' | 'update' | 'delete' | 'upsert';

/** One operation in a transactional batch — same fields as a single write. */
export interface TxnOperation {
  op: TxnOp;
  /** Target resource (table/collection) on the mount. */
  resource: string;
  /** Row data for insert / update / upsert. */
  data?: Record<string, unknown>;
  /** WHERE / filter for update / delete. */
  filter?: Record<string, unknown>;
  /** Idempotency key forwarded to the engine. */
  idempotencyKey?: string;
}

/**
 * Request for `client.txn.execute()` — a single-mount atomic batch. Every op
 * runs in one backend transaction on `databaseId` and commits all-or-nothing
 * (rolled back on the first failure). The engine must be transactional
 * (postgresql/mysql); other engines are rejected.
 */
export interface TxnExecuteInput {
  /** Mount id (dbId); all operations run in one transaction on it. */
  databaseId: string;
  /** 1–50 write ops applied atomically (all-or-nothing). */
  operations: TxnOperation[];
}

/** Per-operation outcome inside a committed transaction. */
export interface TxnOpResult {
  op: string;
  resource: string;
  rowCount: number;
}

/** Result of a single-mount atomic batch. */
export interface TxnResult {
  guarantee: 'atomic';
  mount: string;
  results: TxnOpResult[];
}

// ── Schema introspection + DDL (/query/v1/:dbId/schema) ─────────────────────

/**
 * Engine-agnostic normalized column types returned by `schema.describe()`.
 * `objectid` and `unknown` are describe-only — DDL rejects them (see
 * {@link DdlColumnType}).
 */
export type NormalizedType =
  | 'text'
  | 'integer'
  | 'float'
  | 'decimal'
  | 'boolean'
  | 'date'
  | 'datetime'
  | 'json'
  | 'uuid'
  | 'enum'
  | 'array'
  | 'objectid'
  | 'unknown';

/** Normalized types creatable via DDL (`objectid`/`unknown` are describe-only). */
export type DdlColumnType = Exclude<NormalizedType, 'objectid' | 'unknown'>;

/** One column of a described table (snake_case — the exact wire shape). */
export interface ColumnSchema {
  name: string;
  /** Engine-native type, e.g. `character varying(255)` or `int unsigned`. */
  native_type: string;
  normalized_type: NormalizedType;
  nullable: boolean;
  /** Raw engine default expression, or `null` when the column has none. */
  default: string | null;
  /** Allowed values when `normalized_type` is `enum`; `null` otherwise. */
  enum_values: string[] | null;
  /** Foreign-key target, or `null` when the column references nothing. */
  references: { table: string; column: string } | null;
  /** `true` only for Mongo sample-based inference (no `$jsonSchema` validator). */
  inferred: boolean;
}

/** One table/collection of a described database. */
export interface TableSchema {
  name: string;
  primary_key: string[];
  columns: ColumnSchema[];
}

/**
 * Live engine capability descriptor embedded in `schema.describe()` responses.
 * Mirrors the Rust router's `/v1/capabilities` per-engine payload (the same
 * source `introspectEngines()` validates against). Kept loose
 * (`[key: string]: unknown`) so a new Rust flag does not break the SDK.
 */
export interface SchemaEngineCapabilities {
  read: boolean;
  write: boolean;
  upsert: boolean;
  batch?: boolean;
  aggregate?: boolean;
  /** Engine answers `GET /query/v1/:dbId/schema` (describe). */
  introspect?: boolean;
  /** Engine answers `POST /query/v1/:dbId/schema/ddl` — distinct from `ddl`. */
  schema_ddl?: boolean;
  stream: boolean;
  /** Admin migration-batch surface (`/admin/v1/migrate`) — NOT `schema_ddl`. */
  ddl: boolean;
  transactions: boolean;
  [key: string]: unknown;
}

/**
 * Response of `client.schema.describe()` (`GET /query/v1/:dbId/schema`) —
 * the mount's tables with normalized column types plus the engine's live
 * capability descriptor, so one call tells a client both what the data looks
 * like and what it may do with it.
 */
export interface NormalizedSchema {
  dbId: string;
  engine: string;
  /** `null` when the capabilities fetch failed (the schema is still served). */
  capabilities: SchemaEngineCapabilities | null;
  tables: TableSchema[];
}

/**
 * One DDL column definition (snake_case — the exact wire shape).
 * `nullable`/`default`/`enum_values` may be omitted: for `add_column` /
 * `create_table` the server defaults them (nullable, no default); for
 * `alter_column_type` an omitted attribute means "keep what the column has
 * today" (the server merges with the current column).
 */
export interface DdlColumnDef {
  name: string;
  normalized_type: DdlColumnType;
  /** Whether NULLs are allowed (defaults to `true` on create/add). */
  nullable?: boolean;
  /** Raw engine default expression (`0`, `'pending'`, `now()`); `null` clears it. */
  default?: string | null;
  /** Allowed values — required when `normalized_type` is `enum`. */
  enum_values?: string[] | null;
}

/** The supported schema-DDL operations (snake_case, the wire values). */
export type SchemaDdlOp =
  | 'add_column'
  | 'drop_column'
  | 'alter_column_type'
  | 'create_table'
  | 'drop_table';

/** `add_column`: append `column` to `table`. */
export interface SchemaDdlAddColumnInput {
  op: 'add_column';
  table: string;
  column: DdlColumnDef;
}

/** `alter_column_type`: retype `column.name` (omitted attributes are kept). */
export interface SchemaDdlAlterColumnTypeInput {
  op: 'alter_column_type';
  table: string;
  column: DdlColumnDef;
}

/** `create_table`: create `table` with `columns` and a `primary_key`. */
export interface SchemaDdlCreateTableInput {
  op: 'create_table';
  table: string;
  columns: DdlColumnDef[];
  primary_key: string[];
}

/** `drop_column`: destructive — requires `confirm: true` (400 otherwise). */
export interface SchemaDdlDropColumnInput {
  op: 'drop_column';
  table: string;
  column_name: string;
  confirm: true;
}

/** `drop_table`: destructive — requires `confirm: true` (400 otherwise). */
export interface SchemaDdlDropTableInput {
  op: 'drop_table';
  table: string;
  confirm: true;
}

/**
 * Body of `client.schema.ddl()` — ONE operation per request (deliberate:
 * MySQL DDL is auto-commit, a batch would fake atomicity). The union makes
 * each op's required fields — and `confirm: true` on destructive ops — a
 * compile-time requirement, mirroring the server's 400 guard.
 */
export type SchemaDdlInput =
  | SchemaDdlAddColumnInput
  | SchemaDdlAlterColumnTypeInput
  | SchemaDdlCreateTableInput
  | SchemaDdlDropColumnInput
  | SchemaDdlDropTableInput;

/** Result of an applied schema-DDL operation. */
export interface SchemaDdlResult {
  op: SchemaDdlOp;
  table: string;
  /** `'applied'` on success (failures surface as `MiniBaasError` instead). */
  status: string;
  dbId: string;
}

// ── Webhooks (admin-only, /admin/v1/webhooks) ────────────────────────────────

/** Public webhook subscription view (secrets are write-only and never echoed). */
export interface WebhookSubscription {
  id: string;
  tenant_id: string;
  name: string;
  url: string;
  event_types: string[];
  aggregates: string[];
  active: boolean;
  headers: Record<string, string>;
  max_attempts: number;
  timeout_ms: number;
  created_at: string;
  updated_at: string;
}

/** Body for creating a webhook subscription. */
export interface WebhookCreateInput {
  name: string;
  url: string;
  /** HMAC signing secret (write-only — never returned by list/get). */
  secret: string;
  event_types?: string[];
  aggregates?: string[];
  active?: boolean;
  headers?: Record<string, string>;
  max_attempts?: number;
  timeout_ms?: number;
}

/** Body for patching a webhook subscription (all fields optional). */
export interface WebhookUpdateInput {
  url?: string;
  secret?: string;
  event_types?: string[];
  aggregates?: string[];
  active?: boolean;
  headers?: Record<string, string>;
  max_attempts?: number;
  timeout_ms?: number;
}

/** A webhook delivery attempt ledger row. */
export interface WebhookDelivery {
  id: number;
  subscription_id: string;
  tenant_id: string;
  event_id: string;
  aggregate: string;
  event_type: string;
  status: string;
  attempts: number;
  last_error: string | null;
  last_status_code: number | null;
  next_attempt_at: string;
  delivered_at: string | null;
  created_at: string;
}

// ── Tenants (admin-only, /admin/v1/tenants + /admin/v1/provision) ─────────────

/** Public projection of a tenant. */
export interface Tenant {
  id: string;
  uuid: string;
  name: string;
  status: string;
  plan: string;
  owner_user_id: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

/** Body for creating a tenant. */
export interface TenantCreateInput {
  id: string;
  name: string;
  plan?: string;
  owner_user_id?: string;
  metadata?: Record<string, unknown>;
}

/** Body for patching a tenant. */
export interface TenantUpdateInput {
  name?: string;
  plan?: string;
  status?: string;
  metadata?: Record<string, unknown>;
}

/** Redacted API-key view. The full key is only returned once, on issue. */
export interface TenantApiKey {
  id: string;
  tenant_id: string;
  name: string;
  key_prefix: string;
  scopes: string[];
  created_at: string;
  expires_at: string | null;
  last_used_at: string | null;
  revoked_at: string | null;
}

/** Issued key response — carries the cleartext `key` exactly once. */
export interface TenantApiKeyIssued extends TenantApiKey {
  key: string;
}

/** Body for `client.admin.tenants.bootstrap()`. */
export interface TenantBootstrapInput {
  owner_user_id?: string;
  default_role_name?: string;
  default_key_name?: string;
  seed_roles?: boolean;
}

/** Result of a bootstrap (idempotent; api_key omitted on re-bootstrap). */
export interface TenantBootstrapResult {
  tenant: Tenant;
  api_key?: TenantApiKeyIssued;
  roles: string[];
  created: boolean;
  key_reuse?: boolean;
}

/** One data mount to register inside a provision request. */
export interface ProvisionMountSpec {
  engine: string;
  name: string;
  connection_string: string;
  /** "shared_rls" (default), "schema_per_tenant", or "db_per_tenant". */
  isolation?: string;
}

/** Body for `client.admin.provision()` — a declarative tenant stack (G2). */
export interface ProvisionInput {
  tenant: string;
  name?: string;
  owner_user_id?: string;
  default_role_name?: string;
  default_key_name?: string;
  seed_roles?: boolean;
  mounts?: ProvisionMountSpec[];
}

/** Per-mount reconcile outcome. */
export interface ProvisionMountResult {
  engine: string;
  name: string;
  status: string;
  id?: string;
  schema?: string;
  error?: string;
}

/** Result of a declarative provision/reconcile. */
export interface ProvisionResult {
  tenant: Tenant;
  api_key?: TenantApiKeyIssued;
  key_reuse?: boolean;
  created: boolean;
  roles: string[];
  mounts: ProvisionMountResult[];
}

// ── Admin migrate (admin-only, /admin/v1/migrate → Rust data plane) ───────────

/** Signed identity envelope the data-plane migrate endpoint requires. */
export interface MigrateIdentity {
  tenant_id: string;
  /** Optional server-side (Rust `IdentitySource.user_id` is `Option<String>`). */
  user_id?: string;
  /** Closed set — matches the Rust `IdentitySource` enum (snake_case). */
  source: 'signed_envelope' | 'jwt' | 'service_token' | 'test';
  roles: string[];
}

/** Credential reference for the migrate mount descriptor. */
export interface MigrateCredentialRef {
  provider: string;
  reference: string;
  version: string;
}

/** Target mount descriptor for a migration. */
export interface MigrateMount {
  id: string;
  tenant_id: string;
  engine: string;
  name: string;
  credential_ref: MigrateCredentialRef;
  /** Inline DSN (alternative to a registered credential_ref). */
  inline_dsn?: string;
}

/** Body for `client.admin.migrate.run()` — per-tenant schema migration. */
export interface MigrateInput {
  identity: MigrateIdentity;
  mount: MigrateMount;
  /** Idempotency marker name for this migration. */
  name: string;
  /** Ordered DDL/DML statements applied in one migration. */
  statements: string[];
}

// ── Edge functions (/functions/v1) ───────────────────────────────────────────

/** Body for deploying a function's source. */
export interface FunctionDeployInput {
  name: string;
  /** TypeScript/JavaScript source (max 256KB). */
  code: string;
  /** Optional runtime hint (forward-compat; the runtime documents `runtime?`). */
  runtime?: string;
}

/** Result of a deploy. */
export interface FunctionDeployResult {
  name: string;
  bytes: number;
}

/** Metadata for a deployed function. */
export interface FunctionSummary {
  name: string;
  bytes: number;
  updated_at: string;
}

/** Full source of a deployed function. */
export interface FunctionSource {
  name: string;
  code: string;
}

/** Options for invoking a function. */
export interface FunctionInvokeOptions {
  /** HTTP method handed to the function (defaults to POST). */
  method?: string;
  /** Extra request headers forwarded to the function. */
  headers?: HeadersInit;
}

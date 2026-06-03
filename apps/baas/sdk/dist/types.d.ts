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
    run<TResult = unknown, TPayload = Record<string, unknown>>(action: string, payload?: TPayload): Promise<TResult>;
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

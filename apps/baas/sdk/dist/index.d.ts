import { AnalyticsClient } from './domains/analytics.js';
import { AuthClient } from './domains/auth.js';
import { QueryClient, ResourceQueryBuilder } from './domains/query.js';
import { RestClient, RestResourceBuilder } from './domains/rest.js';
import { SchemaClient } from './domains/schema.js';
import { StorageClient } from './domains/storage.js';
import { TxnClient } from './domains/txn.js';
import { WebhooksClient } from './domains/webhooks.js';
import { AdminClient } from './domains/admin.js';
import { FunctionsClient } from './domains/functions.js';
import { GraphqlClient } from './domains/graphql.js';
import { RealtimeClient } from './domains/realtime-client.js';
import { type EngineId, type EnginesResponse } from './generated/engines.js';
import type { EngineClient } from './domains/engine-clients.js';
import { type SessionStorageAdapter } from './core/storage.js';
import type { ClientSession, SessionInput } from './core/session.js';
import type { RestRequestOptions } from './types.js';
export type { AuthSession, ClientSession, SessionInput, User, } from './core/session.js';
export type { SessionStorageAdapter } from './core/storage.js';
export { MiniBaasError, MiniBaasTimeoutError } from './core/errors.js';
export type { AnalyticsTrackInput, PresignInput, QueryRunInput, QueryRunResponse, RecoverInput, FilterPrimitive, RestFilterOperator, RestMutationOptions, RestOrderOptions, RestQueryBuilder as RestQueryBuilderApi, RestQueryOptions, RestRequestOptions, RestResourceBuilder as RestResourceBuilderApi, SignInWithPasswordInput, SignUpInput, UpdateUserInput, VerifyInput, OAuthProvider, SignInWithOAuthInput, SignInWithOAuthResult, MfaFactorType, MfaEnrollInput, MfaEnrollResult, MfaChallengeInput, MfaChallengeResult, MfaVerifyInput, TxnExecuteInput, TxnOp, TxnOperation, TxnOpResult, TxnResult, WebhookCreateInput, WebhookDelivery, WebhookSubscription, WebhookUpdateInput, Tenant, TenantApiKey, TenantApiKeyIssued, TenantBootstrapInput, TenantBootstrapResult, TenantCreateInput, TenantUpdateInput, ProvisionInput, ProvisionMountResult, ProvisionMountSpec, ProvisionResult, MigrateCredentialRef, MigrateIdentity, MigrateInput, MigrateMount, FunctionDeployInput, FunctionDeployResult, FunctionInvokeOptions, FunctionSource, FunctionSummary, FunctionTrigger, FunctionTriggerCreateInput, FunctionSchedule, FunctionScheduleCreateInput, FunctionSecretMeta, FunctionSecretSetInput, ColumnSchema, DdlColumnDef, DdlColumnType, NormalizedSchema, NormalizedType, SchemaDdlAddColumnInput, SchemaDdlAlterColumnTypeInput, SchemaDdlCreateTableInput, SchemaDdlDropColumnInput, SchemaDdlDropTableInput, SchemaDdlInput, SchemaDdlOp, SchemaDdlResult, SchemaEngineCapabilities, TableSchema, GraphqlError, GraphqlQueryOptions, GraphqlRequest, GraphqlResponse, } from './types.js';
export { SchemaClient } from './domains/schema.js';
export { TxnClient } from './domains/txn.js';
export { WebhooksClient } from './domains/webhooks.js';
export { AdminClient, MigrateClient, TenantsClient } from './domains/admin.js';
export { FunctionsClient } from './domains/functions.js';
export { StorageClient, StorageBucketClient } from './domains/storage.js';
export { RestClient, RestResourceBuilder, RestQueryBuilder } from './domains/rest.js';
export { AuthClient, AuthAdminClient, AuthMfaClient } from './domains/auth.js';
export type { StorageObject, BucketInfo, UploadResult, UploadOptions, UploadBody } from './domains/storage.js';
export { GraphqlClient } from './domains/graphql.js';
export { RealtimeClient } from './domains/realtime-client.js';
export type { PresenceMember, RealtimeEvent, RealtimeSubscribeOptions, RealtimeSubscription, } from './domains/realtime-client.js';
export interface RetryOptions {
    attempts?: number;
    delayMs?: number;
    retryOn?: number[];
}
export interface MiniBaasClientOptions {
    url: string;
    anonKey: string;
    fetch?: typeof fetch;
    accessToken?: string;
    refreshToken?: string;
    serviceRoleKey?: string;
    defaultDatabaseId?: string;
    persistSession?: boolean;
    storage?: SessionStorageAdapter;
    storageKey?: string;
    timeoutMs?: number;
    retry?: number | RetryOptions;
}
export declare class MiniBaasClient {
    readonly auth: AuthClient;
    readonly query: QueryClient;
    readonly rest: RestClient;
    readonly storage: StorageClient;
    readonly analytics: AnalyticsClient;
    /** Single-mount atomic write batches (`POST /query/v1/txn`). */
    readonly txn: TxnClient;
    /** Engine-agnostic schema introspection + DDL (`/query/v1/:dbId/schema`). */
    readonly schema: SchemaClient;
    /** Edge functions (`/functions/v1`). */
    readonly functions: FunctionsClient;
    /**
     * GraphQL passthrough to PostgREST's pg_graphql endpoint (`/graphql/v1`).
     * Requires the `pg_graphql` extension in Postgres (see route docs).
     */
    readonly graphql: GraphqlClient;
    /**
     * Realtime WebSocket client — DB change streams, ephemeral broadcast
     * (client→client), and presence (who's online). See {@link RealtimeClient}.
     */
    readonly realtime: RealtimeClient;
    /**
     * Webhook subscription registry. **Admin-only / server-side**: requires
     * `serviceRoleKey`; the gateway route is internal-only.
     */
    readonly webhooks: WebhooksClient;
    /**
     * Control-plane surface (tenants / provision / migrate). **Admin-only /
     * server-side**: requires `serviceRoleKey`; routes are internal-only.
     */
    readonly admin: AdminClient;
    private readonly http;
    private readonly anonKey;
    constructor(options: MiniBaasClientOptions);
    from<Row = Record<string, unknown>>(resource: string): RestResourceBuilder<Row>;
    fromQuery<Row = Record<string, unknown>>(resource: string, databaseId?: string): ResourceQueryBuilder<Row>;
    /**
     * Open a **capability-typed** client against one engine + database + resource.
     *
     * The returned object's shape is derived from `ENGINE_CAPS[E]` at compile
     * time: `.upsert()` is only present when the engine advertises
     * `upsert: true`, `.subscribe()` only when `stream: true`, etc. Calling
     * a missing method is a TypeScript compile error — not a runtime surprise.
     *
     * @example
     *   const pg = client.engine<'postgresql', User>(dbId, 'users');
     *   await pg.list({ filter: { active: true } });
     *   await pg.transaction(async (tx) => tx.insert({ name: 'Alice' }));
     *   await pg.upsert({ id: 1 });   // ❌ compile error
     */
    engine<E extends EngineId, Row = Record<string, unknown>>(engine: E, databaseId: string, resource: string): EngineClient<E, Row>;
    /**
     * Fetch `/engines` from the running query-router and compare it against
     * the static catalog shipped in `generated/engines.ts`. Resolves to the
     * server-side descriptor; throws if any engine drifts.
     */
    introspectEngines(): Promise<EnginesResponse>;
    rpc<TResult = unknown, TPayload = Record<string, unknown>>(name: string, payload?: TPayload, options?: RestRequestOptions): Promise<TResult>;
    setSession(session: SessionInput): void;
    getSession(): ClientSession | undefined;
    clearSession(): void;
    realtimeUrl(channel?: string): string;
}
export declare function createClient(options: MiniBaasClientOptions): MiniBaasClient;
export { ENGINE_CAPS, ENGINE_IDS } from './generated/engines.js';
export type { EngineCaps, EngineDescriptor, EngineId, EnginesResponse, StreamableEngine, TransactionalEngine, UpsertableEngine, } from './generated/engines.js';
export type { EngineClient } from './domains/engine-clients.js';

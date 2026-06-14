/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   index.ts                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:37:19 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
import { AnalyticsClient } from './domains/analytics.js';
import { AuthClient } from './domains/auth.js';
import { QueryClient } from './domains/query.js';
import { RestClient } from './domains/rest.js';
import { SchemaClient } from './domains/schema.js';
import { StorageClient } from './domains/storage.js';
import { TxnClient } from './domains/txn.js';
import { WebhooksClient } from './domains/webhooks.js';
import { AdminClient } from './domains/admin.js';
import { AccountClient } from './domains/account.js';
import { FunctionsClient } from './domains/functions.js';
import { GraphqlClient } from './domains/graphql.js';
import { RealtimeClient } from './domains/realtime-client.js';
import { HttpClient } from './core/http.js';
import { routes } from './core/routes.js';
import { makeEngineClient } from './domains/engine-clients.js';
import { ENGINE_IDS } from './generated/engines.js';
import { createBrowserStorageAdapter, createMemoryStorageAdapter, } from './core/storage.js';
export { MiniBaasError, MiniBaasTimeoutError, MiniBaasNetworkError, MiniBaasClientError, MiniBaasBadRequestError, MiniBaasUnauthorizedError, MiniBaasForbiddenError, MiniBaasNotFoundError, MiniBaasConflictError, MiniBaasRateLimitError, MiniBaasServerError, } from './core/errors.js';
export { SchemaClient } from './domains/schema.js';
export { TxnClient } from './domains/txn.js';
export { WebhooksClient } from './domains/webhooks.js';
export { AdminClient, MigrateClient, TenantsClient } from './domains/admin.js';
export { AccountClient } from './domains/account.js';
export { FunctionsClient } from './domains/functions.js';
export { StorageClient, StorageBucketClient } from './domains/storage.js';
export { RestClient, RestResourceBuilder, RestQueryBuilder } from './domains/rest.js';
export { AuthClient, AuthAdminClient, AuthMfaClient } from './domains/auth.js';
export { GraphqlClient } from './domains/graphql.js';
export { RealtimeClient } from './domains/realtime-client.js';
export class MiniBaasClient {
    auth;
    query;
    rest;
    storage;
    analytics;
    /** Single-mount atomic write batches (`POST /query/v1/txn`). */
    txn;
    /** Engine-agnostic schema introspection + DDL (`/query/v1/:dbId/schema`). */
    schema;
    /** Edge functions (`/functions/v1`). */
    functions;
    /**
     * GraphQL passthrough to PostgREST's pg_graphql endpoint (`/graphql/v1`).
     * Requires the `pg_graphql` extension in Postgres (see route docs).
     */
    graphql;
    /**
     * Realtime WebSocket client — DB change streams, ephemeral broadcast
     * (client→client), and presence (who's online). See {@link RealtimeClient}.
     */
    realtime;
    /**
     * Webhook subscription registry. **Admin-only / server-side**: requires
     * `serviceRoleKey`; the gateway route is internal-only.
     */
    webhooks;
    /**
     * Control-plane surface (tenants / provision / migrate). **Admin-only /
     * server-side**: requires `serviceRoleKey`; routes are internal-only.
     */
    admin;
    /**
     * Tenant **self-service** control (`/v1/tenants/me*`) — read your plan,
     * entitlements & usage, manage your own API keys, change plan. Works with the
     * session JWT or a tenant API key (no service-role key needed). See
     * {@link AccountClient}.
     */
    account;
    http;
    anonKey;
    constructor(options) {
        const sessionStorage = resolveSessionStorage(options);
        const initialSession = sessionStorage.load() ??
            (options.accessToken
                ? { accessToken: options.accessToken, refreshToken: options.refreshToken }
                : undefined);
        this.anonKey = options.anonKey;
        this.http = new HttpClient({
            baseUrl: options.url,
            anonKey: options.anonKey,
            fetch: options.fetch,
            sessionStorage,
            session: initialSession,
            timeoutMs: options.timeoutMs,
            retry: options.retry,
        });
        this.auth = new AuthClient(this.http, options.serviceRoleKey);
        this.query = new QueryClient(this.http, options.defaultDatabaseId ?? 'default');
        this.rest = new RestClient(this.http);
        this.storage = new StorageClient(this.http);
        this.analytics = new AnalyticsClient(this.http);
        this.txn = new TxnClient(this.http);
        this.schema = new SchemaClient(this.http);
        this.functions = new FunctionsClient(this.http, options.serviceRoleKey);
        this.graphql = new GraphqlClient(this.http);
        this.realtime = new RealtimeClient(this.http);
        this.webhooks = new WebhooksClient(this.http, options.serviceRoleKey);
        this.admin = new AdminClient(this.http, options.serviceRoleKey);
        this.account = new AccountClient(this.http);
    }
    from(resource) {
        return this.rest.from(resource);
    }
    fromQuery(resource, databaseId) {
        return this.query.from(resource, databaseId);
    }
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
    engine(engine, databaseId, resource) {
        return makeEngineClient(this.http, engine, databaseId, resource);
    }
    /**
     * Fetch `/engines` from the running query-router and compare it against
     * the static catalog shipped in `generated/engines.ts`. Resolves to the
     * server-side descriptor; throws if any engine drifts.
     */
    async introspectEngines() {
        const response = await this.http.request(routes.query.engines, { method: 'GET' });
        const liveIds = new Set(response.engines);
        const staticIds = new Set(ENGINE_IDS);
        for (const id of liveIds) {
            if (!staticIds.has(id)) {
                throw new Error(`Engine '${id}' is live on the server but missing from the SDK catalog — regenerate with codegen-engines.mjs.`);
            }
        }
        for (const id of staticIds) {
            if (!liveIds.has(id)) {
                throw new Error(`Engine '${id}' is in the SDK catalog but not registered on the server — drift detected.`);
            }
        }
        return response;
    }
    rpc(name, payload, options) {
        return this.rest.rpc(name, payload, options);
    }
    setSession(session) {
        this.http.setSession(session);
    }
    getSession() {
        return this.http.getSession();
    }
    clearSession() {
        this.http.clearSession();
    }
    realtimeUrl(channel = 'default') {
        const url = this.http.createRealtimeUrl(channel);
        return url.toString();
    }
}
export function createClient(options) {
    return new MiniBaasClient(options);
}
// ── M10: engine-aware exports ────────────────────────────────────────────────
export { ENGINE_CAPS, ENGINE_IDS } from './generated/engines.js';
function resolveSessionStorage(options) {
    if (options.storage)
        return options.storage;
    if (options.persistSession === false)
        return createMemoryStorageAdapter();
    return createBrowserStorageAdapter(options.storageKey) ?? createMemoryStorageAdapter();
}

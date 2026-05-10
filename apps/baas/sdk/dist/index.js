import { AnalyticsClient } from './domains/analytics.js';
import { AuthClient } from './domains/auth.js';
import { QueryClient } from './domains/query.js';
import { RestClient } from './domains/rest.js';
import { StorageClient } from './domains/storage.js';
import { HttpClient } from './core/http.js';
import { createBrowserStorageAdapter, createMemoryStorageAdapter, } from './core/storage.js';
export { MiniBaasError, MiniBaasTimeoutError } from './core/errors.js';
export class MiniBaasClient {
    auth;
    query;
    rest;
    storage;
    analytics;
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
    }
    from(resource) {
        return this.rest.from(resource);
    }
    fromQuery(resource, databaseId) {
        return this.query.from(resource, databaseId);
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
        url.searchParams.set('apikey', this.anonKey);
        const session = this.http.getSession();
        if (session?.accessToken)
            url.searchParams.set('access_token', session.accessToken);
        return url.toString();
    }
}
export function createClient(options) {
    return new MiniBaasClient(options);
}
function resolveSessionStorage(options) {
    if (options.storage)
        return options.storage;
    if (options.persistSession === false)
        return createMemoryStorageAdapter();
    return createBrowserStorageAdapter(options.storageKey) ?? createMemoryStorageAdapter();
}

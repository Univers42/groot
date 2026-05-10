import { AnalyticsClient } from './domains/analytics.js';
import { AuthClient } from './domains/auth.js';
import { QueryClient, ResourceQueryBuilder } from './domains/query.js';
import { RestClient, RestResourceBuilder } from './domains/rest.js';
import { StorageClient } from './domains/storage.js';
import { type SessionStorageAdapter } from './core/storage.js';
import type { ClientSession, SessionInput } from './core/session.js';
import type { RestRequestOptions } from './types.js';
export type { AuthSession, ClientSession, SessionInput, User, } from './core/session.js';
export type { SessionStorageAdapter } from './core/storage.js';
export { MiniBaasError, MiniBaasTimeoutError } from './core/errors.js';
export type { AnalyticsTrackInput, PresignInput, QueryRunInput, QueryRunResponse, RecoverInput, RestFilterOperator, RestMutationOptions, RestQueryOptions, RestRequestOptions, RestResourceBuilder as RestResourceBuilderApi, SignInWithPasswordInput, SignUpInput, UpdateUserInput, VerifyInput, } from './types.js';
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
    private readonly http;
    private readonly anonKey;
    constructor(options: MiniBaasClientOptions);
    from<Row = Record<string, unknown>>(resource: string): RestResourceBuilder<Row>;
    fromQuery<Row = Record<string, unknown>>(resource: string, databaseId?: string): ResourceQueryBuilder<Row>;
    rpc<TResult = unknown, TPayload = Record<string, unknown>>(name: string, payload?: TPayload, options?: RestRequestOptions): Promise<TResult>;
    setSession(session: SessionInput): void;
    getSession(): ClientSession | undefined;
    clearSession(): void;
    realtimeUrl(channel?: string): string;
}
export declare function createClient(options: MiniBaasClientOptions): MiniBaasClient;

import { type ClientSession, type SessionInput } from './session.js';
import type { SessionStorageAdapter } from './storage.js';
import type { RetryOptions } from '../index.js';
interface HttpClientOptions {
    baseUrl: string;
    anonKey: string;
    fetch?: typeof fetch;
    sessionStorage: SessionStorageAdapter;
    session?: ClientSession;
    timeoutMs?: number;
    retry?: number | RetryOptions;
}
export interface RequestOptions {
    method?: string;
    body?: unknown;
    headers?: HeadersInit;
    auth?: boolean;
    apiKey?: string;
    bearerToken?: string;
}
export declare class HttpClient {
    private readonly baseUrl;
    private readonly anonKey;
    private readonly fetchImpl;
    private readonly sessionStorage;
    private readonly timeoutMs;
    private readonly retry;
    private session?;
    constructor(options: HttpClientOptions);
    setSession(session: SessionInput): void;
    getSession(): ClientSession | undefined;
    clearSession(): void;
    createRealtimeUrl(channel: string): URL;
    request<T = unknown>(path: string, init?: RequestOptions): Promise<T>;
    private fetchOnce;
    private buildHeaders;
    private shouldRetry;
}
export {};

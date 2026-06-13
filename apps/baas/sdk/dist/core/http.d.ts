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
    /**
     * M10.b — Build the WS URL the *dlesieur/realtime-agnostic* server exposes.
     *
     * The Rust engine mounts `/ws` (no channel suffix); the channel travels in
     * the subscribe message body. Kong routes `/realtime/v1/ws` → `realtime:4000/ws`
     * with `strip_path: true`, so the SDK must hit exactly `/realtime/v1/ws`
     * — no trailing channel. `apikey` + `access_token` go on the query string
     * because the browser `WebSocket` constructor cannot set request headers.
     */
    createRealtimeWsUrl(): URL;
    getRealtimeAuthToken(): string;
    /** The gateway anon (publishable) key — needed on OAuth redirect URLs. */
    getAnonKey(): string;
    /**
     * Build an absolute gateway URL for a `path` (used by browser-redirect flows
     * like OAuth where the SDK hands back a URL rather than issuing a request).
     */
    buildUrl(path: string): URL;
    request<T = unknown>(path: string, init?: RequestOptions): Promise<T>;
    /**
     * Raw fetch for binary payloads (storage upload/download). Bypasses the JSON
     * (de)serialization of `request()`: the body is sent verbatim and the raw
     * `Response` is returned for the caller to read as blob/arrayBuffer/text.
     * Auth headers (apikey + bearer) are still applied.
     */
    rawFetch(path: string, init?: {
        method?: string;
        body?: BodyInit | null;
        headers?: HeadersInit;
    }): Promise<Response>;
    private fetchOnce;
    private buildHeaders;
    private shouldRetry;
}
export {};

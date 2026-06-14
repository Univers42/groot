/** Base class for every error the SDK throws. Carries the HTTP `status` (0 for
 *  non-HTTP failures like network/timeout) and the parsed server `body`. */
export declare class MiniBaasError extends Error {
    readonly status: number;
    readonly body: unknown;
    constructor(message: string, status: number, body: unknown);
    /** True for the status codes that are safe to retry on idempotent requests. */
    get retryable(): boolean;
}
/** Default set of retryable HTTP statuses (idempotent requests only). */
export declare const RETRYABLE_STATUSES: ReadonlySet<number>;
/** Any 4xx that is not a more specific subclass below. */
export declare class MiniBaasClientError extends MiniBaasError {
    constructor(message: string, status: number, body: unknown);
}
/** 400 — malformed request / validation failure. */
export declare class MiniBaasBadRequestError extends MiniBaasClientError {
    constructor(message: string, body: unknown);
}
/** 401 — missing / invalid credentials. */
export declare class MiniBaasUnauthorizedError extends MiniBaasClientError {
    constructor(message: string, body: unknown);
}
/** 403 — authenticated but not permitted (ABAC/RLS denial). */
export declare class MiniBaasForbiddenError extends MiniBaasClientError {
    constructor(message: string, body: unknown);
}
/** 404 — resource not found. */
export declare class MiniBaasNotFoundError extends MiniBaasClientError {
    constructor(message: string, body: unknown);
}
/** 409 — integrity / uniqueness conflict. */
export declare class MiniBaasConflictError extends MiniBaasClientError {
    constructor(message: string, body: unknown);
}
/** 402 / 429 — quota exceeded or rate limited. Carries the `Retry-After`
 *  hint (in milliseconds) when the server supplied one. */
export declare class MiniBaasRateLimitError extends MiniBaasClientError {
    readonly retryAfterMs?: number | undefined;
    constructor(message: string, status: number, body: unknown, retryAfterMs?: number | undefined);
}
/** Any 5xx server-side failure. */
export declare class MiniBaasServerError extends MiniBaasError {
    constructor(message: string, status: number, body: unknown);
}
/** Transport-level failure (DNS, connection reset, fetch threw). `status` is 0. */
export declare class MiniBaasNetworkError extends MiniBaasError {
    readonly cause?: unknown | undefined;
    constructor(message: string, cause?: unknown | undefined);
    /** Network failures are always retryable on idempotent requests. */
    get retryable(): boolean;
}
/** Request aborted because the (timeout or external) signal fired. `status` is 0. */
export declare class MiniBaasTimeoutError extends MiniBaasError {
    readonly timeoutMs: number;
    /** True when an *external* signal aborted the call (not the timeout). */
    readonly external: boolean;
    constructor(timeoutMs: number, 
    /** True when an *external* signal aborted the call (not the timeout). */
    external?: boolean);
    /** Timeouts are retryable on idempotent requests (the server may be slow,
     *  not wrong); an external abort is never retried. */
    get retryable(): boolean;
}
/**
 * Map an HTTP error `response`/`body` to the most specific typed error.
 * `retryAfterMs` is parsed from the `Retry-After` header by the caller.
 */
export declare function httpError(message: string, status: number, body: unknown, retryAfterMs?: number): MiniBaasError;

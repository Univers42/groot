export declare class MiniBaasError extends Error {
    readonly status: number;
    readonly body: unknown;
    constructor(message: string, status: number, body: unknown);
}
export declare class MiniBaasTimeoutError extends Error {
    readonly timeoutMs: number;
    constructor(timeoutMs: number);
}

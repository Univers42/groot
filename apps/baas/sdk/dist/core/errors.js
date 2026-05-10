export class MiniBaasError extends Error {
    status;
    body;
    constructor(message, status, body) {
        super(message);
        this.status = status;
        this.body = body;
        this.name = 'MiniBaasError';
    }
}
export class MiniBaasTimeoutError extends Error {
    timeoutMs;
    constructor(timeoutMs) {
        super(`MiniBaas request timed out after ${timeoutMs}ms`);
        this.timeoutMs = timeoutMs;
        this.name = 'MiniBaasTimeoutError';
    }
}

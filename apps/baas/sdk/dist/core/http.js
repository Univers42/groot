import { MiniBaasError, MiniBaasTimeoutError } from './errors.js';
import { routes } from './routes.js';
import { normalizeSession } from './session.js';
export class HttpClient {
    baseUrl;
    anonKey;
    fetchImpl;
    sessionStorage;
    timeoutMs;
    retry;
    session;
    constructor(options) {
        this.baseUrl = options.baseUrl.replace(/\/+$/, '');
        this.anonKey = options.anonKey;
        this.fetchImpl = options.fetch ?? fetch;
        this.sessionStorage = options.sessionStorage;
        this.timeoutMs = options.timeoutMs ?? 15_000;
        this.retry = normalizeRetry(options.retry);
        if (options.session)
            this.setSession(options.session);
    }
    setSession(session) {
        this.session = normalizeSession(session);
        this.sessionStorage.save(this.session);
    }
    getSession() {
        return this.session;
    }
    clearSession() {
        this.session = undefined;
        this.sessionStorage.clear();
    }
    createRealtimeUrl(channel) {
        const url = new URL(routes.realtime.channel(channel), this.baseUrl);
        url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
        return url;
    }
    async request(path, init = {}) {
        const attempts = Math.max(1, this.retry.attempts);
        let lastError;
        for (let attempt = 1; attempt <= attempts; attempt += 1) {
            try {
                return await this.fetchOnce(path, init);
            }
            catch (error) {
                lastError = error;
                if (!this.shouldRetry(error, attempt, attempts))
                    throw error;
                await delay(this.retry.delayMs * attempt);
            }
        }
        throw lastError;
    }
    async fetchOnce(path, init) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
        try {
            const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
                method: init.method ?? 'GET',
                headers: this.buildHeaders(init),
                body: init.body === undefined ? undefined : JSON.stringify(init.body),
                signal: controller.signal,
            });
            const body = await parseBody(response);
            if (!response.ok) {
                throw new MiniBaasError(extractErrorMessage(body) ?? response.statusText, response.status, body);
            }
            return body;
        }
        catch (error) {
            if (isAbortError(error))
                throw new MiniBaasTimeoutError(this.timeoutMs);
            throw error;
        }
        finally {
            clearTimeout(timeout);
        }
    }
    buildHeaders(init) {
        const headers = new Headers(init.headers);
        const apiKey = init.apiKey ?? this.anonKey;
        headers.set('apikey', apiKey);
        if (init.auth !== false) {
            headers.set('Authorization', `Bearer ${init.bearerToken ?? this.session?.accessToken ?? apiKey}`);
        }
        if (init.body !== undefined)
            headers.set('Content-Type', 'application/json');
        return headers;
    }
    shouldRetry(error, attempt, attempts) {
        if (attempt >= attempts)
            return false;
        if (error instanceof MiniBaasTimeoutError)
            return true;
        if (error instanceof MiniBaasError)
            return this.retry.retryOn.includes(error.status);
        return true;
    }
}
function normalizeRetry(retry) {
    if (typeof retry === 'number') {
        return { attempts: retry, delayMs: 250, retryOn: [408, 425, 429, 500, 502, 503, 504] };
    }
    return {
        attempts: retry?.attempts ?? 2,
        delayMs: retry?.delayMs ?? 250,
        retryOn: retry?.retryOn ?? [408, 425, 429, 500, 502, 503, 504],
    };
}
async function parseBody(response) {
    const text = await response.text();
    if (!text)
        return undefined;
    try {
        return JSON.parse(text);
    }
    catch {
        return text;
    }
}
function extractErrorMessage(body) {
    if (!body || typeof body !== 'object')
        return undefined;
    const value = body.message ??
        body.error;
    return typeof value === 'string' ? value : undefined;
}
function isAbortError(error) {
    return error instanceof DOMException && error.name === 'AbortError';
}
function delay(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

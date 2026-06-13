/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   http.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:51:48 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
import { MiniBaasError, MiniBaasTimeoutError } from './errors.js';
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
        const url = this.createRealtimeWsUrl();
        url.searchParams.set('channel', channel);
        return url;
    }
    /**
     * M10.b — Build the WS URL the *dlesieur/realtime-agnostic* server exposes.
     *
     * The Rust engine mounts `/ws` (no channel suffix); the channel travels in
     * the subscribe message body. Kong routes `/realtime/v1/ws` → `realtime:4000/ws`
     * with `strip_path: true`, so the SDK must hit exactly `/realtime/v1/ws`
     * — no trailing channel. `apikey` + `access_token` go on the query string
     * because the browser `WebSocket` constructor cannot set request headers.
     */
    createRealtimeWsUrl() {
        const url = new URL('/realtime/v1/ws', this.baseUrl);
        url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
        url.searchParams.set('apikey', this.anonKey);
        if (this.session?.accessToken)
            url.searchParams.set('access_token', this.session.accessToken);
        return url;
    }
    getRealtimeAuthToken() {
        return this.session?.accessToken ?? this.anonKey;
    }
    /** The gateway anon (publishable) key — needed on OAuth redirect URLs. */
    getAnonKey() {
        return this.anonKey;
    }
    /**
     * Build an absolute gateway URL for a `path` (used by browser-redirect flows
     * like OAuth where the SDK hands back a URL rather than issuing a request).
     */
    buildUrl(path) {
        return new URL(`${this.baseUrl}${path}`);
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
    /**
     * Raw fetch for binary payloads (storage upload/download). Bypasses the JSON
     * (de)serialization of `request()`: the body is sent verbatim and the raw
     * `Response` is returned for the caller to read as blob/arrayBuffer/text.
     * Auth headers (apikey + bearer) are still applied.
     */
    async rawFetch(path, init = {}) {
        const headers = new Headers(init.headers);
        headers.set('apikey', this.anonKey);
        headers.set('Authorization', `Bearer ${this.session?.accessToken ?? this.anonKey}`);
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
        try {
            return await this.fetchImpl(`${this.baseUrl}${path}`, {
                method: init.method ?? 'GET',
                headers,
                body: init.body ?? undefined,
                signal: controller.signal,
            });
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

/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rest.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
import { routes } from '../core/routes.js';
export class RestClient {
    http;
    constructor(http) {
        this.http = http;
    }
    async root(options = {}) {
        return this.http.request(routes.rest.root, requestOptions(options));
    }
    from(resource) {
        return new RestResourceBuilder(this.http, resource);
    }
    async rpc(name, payload, options = {}) {
        return this.http.request(routes.rest.rpc(name), {
            ...requestOptions(options),
            method: 'POST',
            body: payload ?? {},
        });
    }
}
export class RestResourceBuilder {
    http;
    resource;
    constructor(http, resource) {
        this.http = http;
        this.resource = resource;
    }
    select(options = {}) {
        return this.http.request(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
            ...requestOptions(options),
            method: 'GET',
        });
    }
    async exists(options = {}) {
        const rows = await this.select({ ...options, columns: 'id', limit: 1 });
        return Array.isArray(rows) && rows.length > 0;
    }
    insert(values, options = {}) {
        return this.http.request(routes.rest.resource(this.resource), {
            ...requestOptions(options),
            method: 'POST',
            headers: mutationHeaders(options),
            body: values,
        });
    }
    update(values, options = {}) {
        return this.http.request(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
            ...requestOptions(options),
            method: 'PATCH',
            headers: mutationHeaders(options),
            body: values,
        });
    }
    delete(options = {}) {
        return this.http.request(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
            ...requestOptions(options),
            method: 'DELETE',
            headers: mutationHeaders(options),
        });
    }
    query(options = {}) {
        return new RestQueryBuilder(this.http, this.resource, options);
    }
    /**
     * Keyset-paginated "changes since a cursor" — an offline-sync foundation.
     *
     * Built entirely from existing PostgREST primitives (no server change):
     *   GET /rest/v1/<resource>?<cursorColumn>=gt.<cursor>&order=<cursorColumn>.asc&limit=<n>
     *
     * Returns one ascending page plus `nextCursor` (the cursor column value of the
     * last row). Drive a full sync by looping while `hasMore`, feeding `nextCursor`
     * back in. The cursor column must be monotonically increasing.
     */
    async changesSince(cursor = null, options = {}) {
        const cursorColumn = String(options.cursorColumn ?? 'updated_at');
        const limit = options.limit ?? 100;
        const comparator = options.comparator ?? 'gt';
        const params = new URLSearchParams();
        if (options.columns)
            params.set('select', options.columns);
        params.set('order', `${cursorColumn}.asc`);
        params.set('limit', String(limit));
        if (cursor !== null && cursor !== undefined) {
            params.append(cursorColumn, `${comparator}.${encodeFilterValue(cursor)}`);
        }
        const rows = await this.http.request(`${routes.rest.resource(this.resource)}?${params.toString()}`, { ...requestOptions(options), method: 'GET' });
        const list = Array.isArray(rows) ? rows : [];
        const hasMore = list.length >= limit;
        const last = list[list.length - 1];
        const nextCursor = last && cursorColumn in last
            ? last[cursorColumn]
            : cursor ?? null;
        return { rows: list, nextCursor: hasMore ? nextCursor : null, hasMore };
    }
}
/**
 * Supabase-js-style fluent REST builder. Every filter/order/range method
 * mutates an internal {@link BuilderState} and returns `this`; the chain is a
 * thenable, so `await client.from('t').query().eq(...).order(...)` issues the
 * GET only when awaited. The resulting URL is byte-identical to what the
 * options-object `RestResourceBuilder.select()` would build for the same
 * filters — same PostgREST request shape, just chained.
 */
export class RestQueryBuilder {
    http;
    resource;
    options;
    state = { order: [], params: [], single: false, maybe: false };
    constructor(http, resource, options) {
        this.http = http;
        this.resource = resource;
        this.options = options;
    }
    select(columns) {
        if (columns)
            this.state.columns = columns;
        return this;
    }
    eq(column, value) { return this.filter(column, 'eq', value); }
    neq(column, value) { return this.filter(column, 'neq', value); }
    gt(column, value) { return this.filter(column, 'gt', value); }
    gte(column, value) { return this.filter(column, 'gte', value); }
    lt(column, value) { return this.filter(column, 'lt', value); }
    lte(column, value) { return this.filter(column, 'lte', value); }
    like(column, pattern) { return this.filter(column, 'like', pattern); }
    ilike(column, pattern) { return this.filter(column, 'ilike', pattern); }
    is(column, value) { return this.filter(column, 'is', value); }
    in(column, values) {
        const list = values.map((v) => encodeInValue(v)).join(',');
        this.state.params.push([String(column), `in.(${list})`]);
        return this;
    }
    or(filter) {
        this.state.params.push(['or', `(${filter})`]);
        return this;
    }
    order(column, options = {}) {
        const dir = options.ascending === false ? 'desc' : 'asc';
        const nulls = options.nullsFirst === undefined
            ? ''
            : options.nullsFirst ? '.nullsfirst' : '.nullslast';
        this.state.order.push(`${String(column)}.${dir}${nulls}`);
        return this;
    }
    limit(count) {
        this.state.limit = count;
        return this;
    }
    range(from, to) {
        this.state.offset = from;
        this.state.limit = to - from + 1;
        return this;
    }
    single() {
        this.state.single = true;
        this.state.maybe = false;
        return this;
    }
    maybeSingle() {
        this.state.single = true;
        this.state.maybe = true;
        return this;
    }
    then(onFulfilled, onRejected) {
        return this.run().then(onFulfilled, onRejected);
    }
    filter(column, operator, value) {
        this.state.params.push([String(column), `${operator}.${encodeFilterValue(value)}`]);
        return this;
    }
    async run() {
        const result = await this.http.request(`${routes.rest.resource(this.resource)}${this.buildQuery()}`, {
            ...requestOptions(this.options),
            method: 'GET',
            headers: this.buildHeaders(),
        });
        return this.coerce(result);
    }
    coerce(result) {
        if (!this.state.single)
            return result;
        if (this.state.maybe) {
            if (result === undefined || result === null)
                return null;
            return (Array.isArray(result) ? (result[0] ?? null) : result);
        }
        return (Array.isArray(result) ? result[0] : result);
    }
    buildHeaders() {
        const headers = new Headers(this.options.headers);
        if (this.state.single) {
            headers.set('Accept', 'application/vnd.pgrst.object+json');
        }
        return this.state.single || this.options.headers ? headers : undefined;
    }
    buildQuery() {
        const params = new URLSearchParams();
        if (this.state.columns)
            params.set('select', this.state.columns);
        if (this.state.limit !== undefined)
            params.set('limit', String(this.state.limit));
        if (this.state.offset !== undefined)
            params.set('offset', String(this.state.offset));
        if (this.state.order.length)
            params.set('order', this.state.order.join(','));
        for (const [key, value] of this.state.params)
            params.append(key, value);
        const value = params.toString();
        return value ? `?${value}` : '';
    }
}
function requestOptions(options) {
    return {
        apiKey: options.apiKey,
        bearerToken: options.bearerToken,
        headers: options.headers,
        timeoutMs: options.timeoutMs,
        signal: options.signal,
    };
}
function mutationHeaders(options) {
    const headers = new Headers(options.headers);
    headers.set('Prefer', options.returning === 'minimal' ? 'return=minimal' : 'return=representation');
    return headers;
}
function queryString(options) {
    const params = new URLSearchParams();
    if (options.columns)
        params.set('select', options.columns);
    if (options.limit !== undefined)
        params.set('limit', String(options.limit));
    if (options.offset !== undefined)
        params.set('offset', String(options.offset));
    if (options.order)
        params.set('order', options.order);
    for (const filter of Object.values(normalizeFilters(options.filters))) {
        params.append(String(filter.column), `${filter.operator}.${encodeFilterValue(filter.value)}`);
    }
    const value = params.toString();
    return value ? `?${value}` : '';
}
function normalizeFilters(filters = {}) {
    if (Array.isArray(filters)) {
        return filters.map((filter) => ({ ...filter, column: String(filter.column) }));
    }
    return Object.entries(filters).map(([column, value]) => ({ column, operator: 'eq', value: value }));
}
function encodeFilterValue(value) {
    if (value === null)
        return 'null';
    return String(value);
}
/** Encode one member of a PostgREST `in.(...)` list (quote strings w/ commas). */
function encodeInValue(value) {
    if (value === null)
        return 'null';
    if (typeof value === 'string' && /[,"()]/.test(value)) {
        return `"${value.replace(/"/g, '\\"')}"`;
    }
    return String(value);
}

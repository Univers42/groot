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
}
function requestOptions(options) {
    return {
        apiKey: options.apiKey,
        bearerToken: options.bearerToken,
        headers: options.headers,
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

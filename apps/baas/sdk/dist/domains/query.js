import { routes } from '../core/routes.js';
export class QueryClient {
    http;
    defaultDatabaseId;
    constructor(http, defaultDatabaseId) {
        this.http = http;
        this.defaultDatabaseId = defaultDatabaseId;
    }
    async run(input) {
        const response = await this.http.request(routes.query.execute, {
            method: 'POST',
            body: toBackendQuery(input, this.defaultDatabaseId),
        });
        return unwrapData(response);
    }
    from(resource, databaseId) {
        return new ResourceQueryBuilder(this, resource, databaseId);
    }
}
export class ResourceQueryBuilder {
    query;
    resource;
    databaseId;
    constructor(query, resource, databaseId) {
        this.query = query;
        this.resource = resource;
        this.databaseId = databaseId;
    }
    select(filter = {}) {
        return this.run('select', { filter });
    }
    insert(values) {
        return this.run('insert', { values });
    }
    update(values, filter = {}) {
        return this.run('update', { values, filter });
    }
    delete(filter = {}) {
        return this.run('delete', { filter });
    }
    run(action, payload) {
        return this.query.run({
            databaseId: this.databaseId,
            action,
            resource: this.resource,
            payload,
        });
    }
}
function toBackendQuery(input, defaultDatabaseId) {
    return {
        database_id: input.databaseId ?? defaultDatabaseId,
        action: input.action,
        resource: input.resource,
        payload: input.payload,
    };
}
function unwrapData(response) {
    if (response && typeof response === 'object' && 'data' in response) {
        return response.data;
    }
    return response;
}

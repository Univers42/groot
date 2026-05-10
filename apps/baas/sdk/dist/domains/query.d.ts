import type { HttpClient } from '../core/http.js';
import type { QueryRunInput, ResourceQueryBuilder as ResourceQueryBuilderApi } from '../types.js';
export declare class QueryClient {
    private readonly http;
    private readonly defaultDatabaseId;
    constructor(http: HttpClient, defaultDatabaseId: string);
    run<TResult = unknown, TPayload = Record<string, unknown>>(input: QueryRunInput<TPayload>): Promise<TResult>;
    from<Row = Record<string, unknown>>(resource: string, databaseId?: string): ResourceQueryBuilder<Row>;
}
export declare class ResourceQueryBuilder<Row = Record<string, unknown>> implements ResourceQueryBuilderApi<Row> {
    private readonly query;
    private readonly resource;
    private readonly databaseId?;
    constructor(query: QueryClient, resource: string, databaseId?: string | undefined);
    select<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
    insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>): Promise<TResult>;
    update<TResult = Row[]>(values: Partial<Row>, filter?: Record<string, unknown>): Promise<TResult>;
    delete<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
    run<TResult = unknown, TPayload = Record<string, unknown>>(action: string, payload?: TPayload): Promise<TResult>;
}

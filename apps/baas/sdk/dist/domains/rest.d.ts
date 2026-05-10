import type { HttpClient } from '../core/http.js';
import type { RestMutationOptions, RestQueryOptions, RestRequestOptions, RestResourceBuilder as RestResourceBuilderApi } from '../types.js';
export declare class RestClient {
    private readonly http;
    constructor(http: HttpClient);
    root(options?: RestRequestOptions): Promise<unknown>;
    from<Row = Record<string, unknown>>(resource: string): RestResourceBuilder<Row>;
    rpc<TResult = unknown, TPayload = Record<string, unknown>>(name: string, payload?: TPayload, options?: RestRequestOptions): Promise<TResult>;
}
export declare class RestResourceBuilder<Row = Record<string, unknown>> implements RestResourceBuilderApi<Row> {
    private readonly http;
    private readonly resource;
    constructor(http: HttpClient, resource: string);
    select<TResult = Row[]>(options?: RestQueryOptions<Row>): Promise<TResult>;
    exists(options?: RestQueryOptions<Row>): Promise<boolean>;
    insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>, options?: RestMutationOptions): Promise<TResult>;
    update<TResult = Row[]>(values: Partial<Row>, options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
    delete<TResult = Row[]>(options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
}

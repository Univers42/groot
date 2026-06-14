import type { HttpClient } from '../core/http.js';
import type { ChangesCursor, ChangesPage, ChangesSinceOptions, FilterPrimitive, RestMutationOptions, RestOrderOptions, RestQueryBuilder as RestQueryBuilderApi, RestQueryOptions, RestRequestOptions, RestResourceBuilder as RestResourceBuilderApi } from '../types.js';
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
    query(options?: RestRequestOptions): RestQueryBuilder<Row>;
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
    changesSince(cursor?: ChangesCursor, options?: ChangesSinceOptions<Row>): Promise<ChangesPage<Row>>;
}
/**
 * Supabase-js-style fluent REST builder. Every filter/order/range method
 * mutates an internal {@link BuilderState} and returns `this`; the chain is a
 * thenable, so `await client.from('t').query().eq(...).order(...)` issues the
 * GET only when awaited. The resulting URL is byte-identical to what the
 * options-object `RestResourceBuilder.select()` would build for the same
 * filters — same PostgREST request shape, just chained.
 */
export declare class RestQueryBuilder<Row = Record<string, unknown>, TResult = Row[]> implements RestQueryBuilderApi<Row, TResult> {
    private readonly http;
    private readonly resource;
    private readonly options;
    private readonly state;
    constructor(http: HttpClient, resource: string, options: RestRequestOptions);
    select(columns?: string): this;
    eq(column: keyof Row | string, value: FilterPrimitive): this;
    neq(column: keyof Row | string, value: FilterPrimitive): this;
    gt(column: keyof Row | string, value: FilterPrimitive): this;
    gte(column: keyof Row | string, value: FilterPrimitive): this;
    lt(column: keyof Row | string, value: FilterPrimitive): this;
    lte(column: keyof Row | string, value: FilterPrimitive): this;
    like(column: keyof Row | string, pattern: string): this;
    ilike(column: keyof Row | string, pattern: string): this;
    is(column: keyof Row | string, value: FilterPrimitive): this;
    in(column: keyof Row | string, values: ReadonlyArray<FilterPrimitive>): this;
    or(filter: string): this;
    order(column: keyof Row | string, options?: RestOrderOptions): this;
    limit(count: number): this;
    range(from: number, to: number): this;
    single(): RestQueryBuilder<Row, Row>;
    maybeSingle(): RestQueryBuilder<Row, Row | null>;
    then<TFulfilled = TResult, TRejected = never>(onFulfilled?: ((value: TResult) => TFulfilled | PromiseLike<TFulfilled>) | null, onRejected?: ((reason: unknown) => TRejected | PromiseLike<TRejected>) | null): Promise<TFulfilled | TRejected>;
    private filter;
    private run;
    private coerce;
    private buildHeaders;
    private buildQuery;
}

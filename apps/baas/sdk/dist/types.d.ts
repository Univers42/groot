export type { AuthSession, User } from './core/session.js';
export interface SignInWithPasswordInput {
    email: string;
    password: string;
}
export interface SignUpInput {
    email: string;
    password: string;
    data?: Record<string, unknown>;
}
export interface RecoverInput {
    email: string;
}
export interface VerifyInput {
    type: 'signup' | 'recovery' | 'magiclink' | 'email_change';
    token?: string;
    token_hash?: string;
}
export interface UpdateUserInput {
    email?: string;
    password?: string;
    data?: Record<string, unknown>;
}
export interface AdminCreateUserInput extends SignUpInput {
    email_confirm?: boolean;
    user_metadata?: Record<string, unknown>;
}
export interface AdminUpdateUserInput {
    email?: string;
    password?: string;
    email_confirm?: boolean;
    user_metadata?: Record<string, unknown>;
    app_metadata?: Record<string, unknown>;
}
export interface AdminGenerateLinkInput extends SignUpInput {
    type: 'signup' | 'recovery' | 'magiclink' | 'email_change_current' | 'email_change_new';
    redirect_to?: string;
    data?: Record<string, unknown>;
}
export interface QueryRunInput<TPayload = Record<string, unknown>> {
    databaseId?: string;
    action: string;
    resource: string;
    payload?: TPayload;
}
export interface QueryRunResponse<TResult = unknown> {
    data: TResult;
    count?: number;
    meta?: Record<string, unknown>;
}
export interface ResourceQueryBuilder<Row = Record<string, unknown>> {
    select<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
    insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>): Promise<TResult>;
    update<TResult = Row[]>(values: Partial<Row>, filter?: Record<string, unknown>): Promise<TResult>;
    delete<TResult = Row[]>(filter?: Record<string, unknown>): Promise<TResult>;
    run<TResult = unknown, TPayload = Record<string, unknown>>(action: string, payload?: TPayload): Promise<TResult>;
}
export type RestFilterOperator = 'eq' | 'neq' | 'gt' | 'gte' | 'lt' | 'lte' | 'like' | 'ilike' | 'is';
export interface RestRequestOptions {
    apiKey?: string;
    bearerToken?: string;
    headers?: HeadersInit;
}
export interface RestQueryOptions<Row = Record<string, unknown>> extends RestRequestOptions {
    columns?: string;
    limit?: number;
    offset?: number;
    order?: string;
    filters?: Partial<Record<keyof Row | string, string | number | boolean | null>> | Array<{
        column: keyof Row | string;
        operator: RestFilterOperator;
        value: string | number | boolean | null;
    }>;
}
export interface RestMutationOptions extends RestRequestOptions {
    returning?: 'representation' | 'minimal';
}
export interface RestResourceBuilder<Row = Record<string, unknown>> {
    select<TResult = Row[]>(options?: RestQueryOptions<Row>): Promise<TResult>;
    exists(options?: RestQueryOptions<Row>): Promise<boolean>;
    insert<TResult = Row>(values: Partial<Row> | Array<Partial<Row>>, options?: RestMutationOptions): Promise<TResult>;
    update<TResult = Row[]>(values: Partial<Row>, options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
    delete<TResult = Row[]>(options?: RestQueryOptions<Row> & RestMutationOptions): Promise<TResult>;
}
export interface PresignInput {
    bucket: string;
    key: string;
    method?: 'GET' | 'PUT';
    contentType?: string;
}
export interface AnalyticsTrackInput {
    eventType: string;
    data?: Record<string, unknown>;
}

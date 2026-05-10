import { routes } from '../core/routes.js';
import type { HttpClient, RequestOptions } from '../core/http.js';
import type {
  RestFilterOperator,
  RestMutationOptions,
  RestQueryOptions,
  RestRequestOptions,
  RestResourceBuilder as RestResourceBuilderApi,
} from '../types.js';

type FilterValue = string | number | boolean | null;

export class RestClient {
  constructor(private readonly http: HttpClient) {}

  async root(options: RestRequestOptions = {}): Promise<unknown> {
    return this.http.request(routes.rest.root, requestOptions(options));
  }

  from<Row = Record<string, unknown>>(resource: string): RestResourceBuilder<Row> {
    return new RestResourceBuilder<Row>(this.http, resource);
  }

  async rpc<TResult = unknown, TPayload = Record<string, unknown>>(
    name: string,
    payload?: TPayload,
    options: RestRequestOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(routes.rest.rpc(name), {
      ...requestOptions(options),
      method: 'POST',
      body: payload ?? {},
    });
  }
}

export class RestResourceBuilder<Row = Record<string, unknown>> implements RestResourceBuilderApi<Row> {
  constructor(
    private readonly http: HttpClient,
    private readonly resource: string,
  ) {}

  select<TResult = Row[]>(options: RestQueryOptions<Row> = {}): Promise<TResult> {
    return this.http.request<TResult>(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
      ...requestOptions(options),
      method: 'GET',
    });
  }

  async exists(options: RestQueryOptions<Row> = {}): Promise<boolean> {
    const rows = await this.select<Row[]>({ ...options, columns: 'id', limit: 1 });
    return Array.isArray(rows) && rows.length > 0;
  }

  insert<TResult = Row>(
    values: Partial<Row> | Array<Partial<Row>>,
    options: RestMutationOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(routes.rest.resource(this.resource), {
      ...requestOptions(options),
      method: 'POST',
      headers: mutationHeaders(options),
      body: values,
    });
  }

  update<TResult = Row[]>(
    values: Partial<Row>,
    options: RestQueryOptions<Row> & RestMutationOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
      ...requestOptions(options),
      method: 'PATCH',
      headers: mutationHeaders(options),
      body: values,
    });
  }

  delete<TResult = Row[]>(options: RestQueryOptions<Row> & RestMutationOptions = {}): Promise<TResult> {
    return this.http.request<TResult>(`${routes.rest.resource(this.resource)}${queryString(options)}`, {
      ...requestOptions(options),
      method: 'DELETE',
      headers: mutationHeaders(options),
    });
  }
}

function requestOptions(options: RestRequestOptions): RequestOptions {
  return {
    apiKey: options.apiKey,
    bearerToken: options.bearerToken,
    headers: options.headers,
  };
}

function mutationHeaders(options: RestMutationOptions): HeadersInit {
  const headers = new Headers(options.headers);
  headers.set('Prefer', options.returning === 'minimal' ? 'return=minimal' : 'return=representation');
  return headers;
}

function queryString<Row>(options: RestQueryOptions<Row>): string {
  const params = new URLSearchParams();
  if (options.columns) params.set('select', options.columns);
  if (options.limit !== undefined) params.set('limit', String(options.limit));
  if (options.offset !== undefined) params.set('offset', String(options.offset));
  if (options.order) params.set('order', options.order);

  for (const filter of Object.values(normalizeFilters(options.filters))) {
    params.append(String(filter.column), `${filter.operator}.${encodeFilterValue(filter.value)}`);
  }

  const value = params.toString();
  return value ? `?${value}` : '';
}

function normalizeFilters<Row>(filters: RestQueryOptions<Row>['filters'] = {}): Array<{ column: string; operator: RestFilterOperator; value: FilterValue }> {
  if (Array.isArray(filters)) {
    return filters.map((filter) => ({ ...filter, column: String(filter.column) }));
  }
  return Object.entries(filters).map(([column, value]) => ({ column, operator: 'eq', value: value as FilterValue }));
}

function encodeFilterValue(value: FilterValue): string {
  if (value === null) return 'null';
  return String(value);
}

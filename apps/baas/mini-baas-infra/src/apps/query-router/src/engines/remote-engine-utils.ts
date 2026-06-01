import { BadRequestException, ServiceUnavailableException } from '@nestjs/common';
import type { AdapterOp, QueryOpts, QueryResult } from '@mini-baas/database';

export interface RemoteConnection {
  baseUrl: string;
  headers?: Record<string, string>;
  database?: string;
  keyspace?: string;
  org?: string;
  bucket?: string;
  token?: string;
}

const RESOURCE_REGEX = /^[\w.:-]{1,128}$/;

export function validateResourceName(resource: string, label: string): void {
  if (!RESOURCE_REGEX.test(resource)) {
    throw new BadRequestException(`Invalid ${label} resource name: ${resource}`);
  }
}

export function parseRemoteConnection(connectionString: string): RemoteConnection {
  try {
    const parsed = JSON.parse(connectionString) as RemoteConnection;
    if (typeof parsed.baseUrl !== 'string' || !/^https?:\/\//i.test(parsed.baseUrl)) {
      throw new Error('baseUrl must be a fully qualified http(s) URL');
    }
    return parsed;
  } catch {
    if (/^https?:\/\//i.test(connectionString)) return { baseUrl: connectionString };
    throw new BadRequestException('connection_string must be JSON with baseUrl or a bare http(s) URL');
  }
}

export function joinUrl(baseUrl: string, path: string): string {
  const base = baseUrl.replace(/\/+$/, '');
  const suffix = path.startsWith('/') ? path : `/${path}`;
  return `${base}${suffix}`;
}

export function getRequiredId(opts: QueryOpts, op: AdapterOp): string {
  const value = opts.filter?.['id'] ?? opts.data?.['id'];
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    const id = String(value).trim();
    if (id) return id;
  }
  throw new BadRequestException(`${op} requires filter.id or data.id`);
}

export function withOwner(data: Record<string, unknown> | undefined, opts: QueryOpts): Record<string, unknown> {
  const out: Record<string, unknown> = data ? { ...data } : {};
  if (opts.userId) out['ownerId'] = opts.userId;
  return out;
}

export async function fetchJson(
  conn: RemoteConnection,
  path: string,
  init: { method?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<unknown> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  Object.assign(headers, conn.headers);
  Object.assign(headers, init.headers);
  if (conn.token && !headers.Authorization) headers.Authorization = `Bearer ${conn.token}`;
  if (init.body !== undefined) headers['Content-Type'] = 'application/json';
  let requestBody: string | undefined;
  if (typeof init.body === 'string') {
    requestBody = init.body;
  } else if (init.body !== undefined) {
    requestBody = JSON.stringify(init.body);
  }

  const response = await fetch(joinUrl(conn.baseUrl, path), {
    method: init.method ?? 'GET',
    headers,
    body: requestBody,
  });

  const text = await response.text();
  if (!response.ok) {
    if (response.status >= 500) {
      throw new ServiceUnavailableException(`Remote engine returned ${response.status}: ${text.slice(0, 300)}`);
    }
    throw new BadRequestException(`Remote engine returned ${response.status}: ${text.slice(0, 300)}`);
  }
  if (!text) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

export function scalarString(value: unknown): string | undefined {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return undefined;
}

export function queryResultFromRows(rows: Record<string, unknown>[]): QueryResult {
  return { rows, rowCount: rows.length };
}

export function rowsFromUnknown(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value.filter((row): row is Record<string, unknown> => !!row && typeof row === 'object');
  if (value && typeof value === 'object') {
    const objectValue = value as Record<string, unknown>;
    if (Array.isArray(objectValue['rows'])) {
      return rowsFromUnknown(objectValue['rows']);
    }
    if (Array.isArray(objectValue['data'])) {
      return rowsFromUnknown(objectValue['data']);
    }
    return [objectValue];
  }
  return [];
}
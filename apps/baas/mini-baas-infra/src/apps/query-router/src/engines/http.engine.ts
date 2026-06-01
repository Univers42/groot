/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   http.engine.ts                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 23:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:41:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  BadRequestException,
  Injectable,
  Logger,
  NotImplementedException,
  ServiceUnavailableException,
} from '@nestjs/common';
import type {
  AdapterOp,
  EngineCaps,
  IDatabaseAdapter,
  QueryOpts,
  QueryResult,
} from '@mini-baas/database';

const RESOURCE_REGEX = /^[\w./-]{1,128}$/;

/** Parsed `connection_string` payload for HttpEngine. */
interface HttpConnection {
  baseUrl: string;
  headers?: Record<string, string>;
  /** Optional path override per operation. Defaults to '/{resource}'. */
  routes?: Partial<Record<AdapterOp, string>>;
  /** Request body shape mode — 'jsonapi', 'plain', or 'restish' (default). */
  shape?: 'plain' | 'restish' | 'jsonapi';
}

/**
 * HTTP adapter (M2 federation).
 *
 * Treats an external REST endpoint as a "database". The adapter-registry
 * stores the base URL + optional auth headers in `connection_string` as a
 * JSON blob (the same field that normally holds a DB DSN). Useful for
 * fronting third-party APIs (Stripe, HubSpot, internal microservices)
 * through the same query-router surface as native engines.
 *
 * Uses Node 20 built-in `fetch` (powered by undici) — no extra runtime dep.
 *
 * Operation → HTTP verb mapping (default REST-ish shape):
 *   list   → GET    /{resource}?<filter & sort & limit & offset>
 *   get    → GET    /{resource}/{filter.id}
 *   insert → POST   /{resource}            body=data
 *   update → PATCH  /{resource}/{filter.id} body=data
 *   delete → DELETE /{resource}/{filter.id}
 *   upsert → PUT    /{resource}/{data.id}   body=data
 */
@Injectable()
export class HttpEngine implements IDatabaseAdapter {
  readonly engine = 'http';
  private readonly logger = new Logger(HttpEngine.name);

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: true,
      txIntra: false,
      stream: false,
      semantic: { joins: 'none', patternSearch: 'remote', ddl: false, migrationVersioning: false, latencyClass: 'remote' },
    };
  }

  async execute(
    connectionString: string,
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Promise<QueryResult> {
    this.validateResource(resource);
    const conn = this.parseConnection(connectionString);

    const idForRow = (): string => {
      const id = this.scalarId(opts.filter?.['id'] ?? opts.data?.['id']).trim();
      if (!id) throw new BadRequestException(`HTTP op '${op}' requires filter.id or data.id`);
      return encodeURIComponent(id);
    };

    let method: string;
    let path: string;
    let body: unknown;

    switch (op) {
      case 'list':
        method = 'GET';
        path = conn.routes?.list ?? `/${resource}`;
        path = this.appendQuery(path, opts);
        break;
      case 'get':
        method = 'GET';
        path = conn.routes?.get ?? `/${resource}/${idForRow()}`;
        break;
      case 'insert':
        method = 'POST';
        path = conn.routes?.insert ?? `/${resource}`;
        body = opts.data;
        break;
      case 'update':
        method = 'PATCH';
        path = conn.routes?.update ?? `/${resource}/${idForRow()}`;
        body = opts.data;
        break;
      case 'delete':
        method = 'DELETE';
        path = conn.routes?.delete ?? `/${resource}/${idForRow()}`;
        break;
      case 'upsert':
        method = 'PUT';
        path = conn.routes?.upsert ?? `/${resource}/${idForRow()}`;
        body = opts.data;
        break;
      default:
        throw new NotImplementedException(`HTTP adapter does not implement op '${op}'`);
    }

    return this.request(conn, method, path, body, opts);
  }

  async listResources(connectionString: string): Promise<string[]> {
    const conn = this.parseConnection(connectionString);
    const url = this.joinUrl(conn.baseUrl, '/');
    try {
      const res = await this.doFetch(conn, url, 'GET');
      const text = await res.text();
      try {
        const json = JSON.parse(text);
        if (Array.isArray(json?.resources)) return json.resources.map(String);
        if (Array.isArray(json)) return json.map(String);
      } catch { /* not JSON — fall through */ }
      return [];
    } catch (err) {
      this.logger.warn(`HttpEngine.listResources failed: ${err instanceof Error ? err.message : String(err)}`);
      return [];
    }
  }

  private validateResource(name: string): void {
    if (!RESOURCE_REGEX.test(name)) {
      throw new BadRequestException(`Invalid HTTP resource path: ${name}`);
    }
  }

  private parseConnection(connectionString: string): HttpConnection {
    try {
      const parsed = JSON.parse(connectionString) as HttpConnection;
      if (typeof parsed.baseUrl !== 'string' || !/^https?:\/\//i.test(parsed.baseUrl)) {
        throw new Error('baseUrl must be a fully qualified http(s) URL');
      }
      return parsed;
    } catch {
      // Allow bare URL as a shorthand connection string.
      if (/^https?:\/\//i.test(connectionString)) {
        return { baseUrl: connectionString };
      }
      throw new BadRequestException(
        'HTTP connection_string must be a JSON { baseUrl, headers?, routes? } or a bare http(s) URL.',
      );
    }
  }

  private joinUrl(base: string, path: string): string {
    const cleanBase = base.replace(/\/+$/, '');
    const cleanPath = path.startsWith('/') ? path : `/${path}`;
    return `${cleanBase}${cleanPath}`;
  }

  private appendQuery(path: string, opts: QueryOpts): string {
    const params = new URLSearchParams();
    if (opts.filter) {
      for (const [k, v] of Object.entries(opts.filter)) {
        if (v == null) continue;
        params.set(k, typeof v === 'string' ? v : JSON.stringify(v));
      }
    }
    if (opts.sort) params.set('sort', JSON.stringify(opts.sort));
    if (opts.limit != null) params.set('limit', String(opts.limit));
    if (opts.offset != null) params.set('offset', String(opts.offset));
    const qs = params.toString();
    if (!qs) return path;
    const separator = path.includes('?') ? '&' : '?';
    return `${path}${separator}${qs}`;
  }

  private async request(
    conn: HttpConnection,
    method: string,
    path: string,
    body: unknown,
    opts: QueryOpts,
  ): Promise<QueryResult> {
    const url = this.joinUrl(conn.baseUrl, path);
    const res = await this.doFetch(conn, url, method, body, opts);

    if (res.status === 204) return { rows: [], rowCount: 0 };

    const text = await res.text();
    let parsed: unknown;
    try {
      parsed = text.length > 0 ? JSON.parse(text) : null;
    } catch {
      parsed = text;
    }

    if (Array.isArray(parsed)) {
      return {
        rows: parsed as Record<string, unknown>[],
        rowCount: parsed.length,
      };
    }
    if (parsed && typeof parsed === 'object' && Array.isArray((parsed as { data?: unknown[] }).data)) {
      const data = (parsed as { data: Record<string, unknown>[] }).data;
      return { rows: data, rowCount: data.length };
    }
    if (parsed && typeof parsed === 'object') {
      return { rows: [parsed as Record<string, unknown>], rowCount: 1 };
    }
    return { rows: [], rowCount: 0 };
  }

  private async doFetch(
    conn: HttpConnection,
    url: string,
    method: string,
    body?: unknown,
    opts?: QueryOpts,
  ): Promise<Response> {
    const headers: Record<string, string> = conn.headers
      ? { Accept: 'application/json', ...conn.headers }
      : { Accept: 'application/json' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (opts?.userId) headers['X-Owner-Id'] = opts.userId;
    if (opts?.idempotencyKey) headers['Idempotency-Key'] = opts.idempotencyKey;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);

    try {
      const requestBody = body === undefined ? undefined : JSON.stringify(body);
      const res = await fetch(url, {
        method,
        headers,
        body: requestBody,
        signal: controller.signal,
      });
      if (!res.ok && res.status >= 500) {
        throw new ServiceUnavailableException(
          `HTTP upstream ${method} ${url} returned ${res.status}`,
        );
      }
      if (!res.ok && res.status >= 400) {
        throw new BadRequestException(
          `HTTP upstream ${method} ${url} returned ${res.status}`,
        );
      }
      return res;
    } finally {
      clearTimeout(timeout);
    }
  }

  private scalarId(value: unknown): string {
    if (value == null) return '';
    if (typeof value === 'string') return value;
    if (typeof value === 'number' || typeof value === 'boolean') return String(value);
    throw new BadRequestException('HTTP row id must be a string, number, or boolean');
  }
}

/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   redis.engine.ts                                    :+:      :+:    :+:   */
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
  NotImplementedException,
} from '@nestjs/common';
import type {
  AdapterOp,
  EngineCaps,
  IDatabaseAdapter,
  QueryOpts,
  QueryResult,
} from '@mini-baas/database';
import IORedis, { type Redis } from 'ioredis';

const RESOURCE_REGEX = /^[\w:.-]{1,128}$/;

/**
 * Redis adapter (M2 federation).
 *
 * Redis is a KV store, not a relational engine — `resource` is treated as a
 * **key prefix** under which one document per row is stored as a HASH. The
 * adapter applies tenant isolation by namespacing each key with the calling
 * user id when a `userId` is provided in {@link QueryOpts}.
 *
 * Mapping:
 *   - `list`    → SCAN over `${resource}:*` (or `${userId}:${resource}:*`) + HGETALL each
 *   - `get`     → HGETALL on `${prefix}:${data.id}`
 *   - `insert`  → HSET on `${prefix}:${id}` (id from data.id or generated)
 *   - `update`  → HSET-merge on existing key (errors if missing)
 *   - `delete`  → DEL on key
 *   - `upsert`  → HSET unconditionally
 */
@Injectable()
export class RedisEngine implements IDatabaseAdapter {
  readonly engine = 'redis';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: true,
      txIntra: false,
      stream: false,
      semantic: { joins: 'none', patternSearch: 'scan', ddl: false, migrationVersioning: false, latencyClass: 'native' },
    };
  }

  async execute(
    connectionString: string,
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Promise<QueryResult> {
    this.validateResource(resource);
    const client = await this.connect(connectionString);

    try {
      switch (op) {
        case 'list':   return await this.list(client, resource, opts);
        case 'get':    return await this.get(client, resource, opts);
        case 'insert': return await this.insert(client, resource, opts);
        case 'update': return await this.update(client, resource, opts);
        case 'delete': return await this.delete(client, resource, opts);
        case 'upsert': return await this.upsert(client, resource, opts);
        default:
          throw new NotImplementedException(`Redis adapter does not implement op '${op}'`);
      }
    } finally {
      client.disconnect();
    }
  }

  async listResources(connectionString: string): Promise<string[]> {
    const client = await this.connect(connectionString);
    try {
      // Surface every distinct namespace (everything before the first ':').
      const namespaces = new Set<string>();
      let cursor = '0';
      do {
        const [next, keys] = await client.scan(cursor, 'COUNT', 500);
        cursor = next;
        for (const k of keys) {
          const ns = k.split(':')[0];
          if (ns) namespaces.add(ns);
        }
      } while (cursor !== '0');
      const collator = new Intl.Collator('en');
      return Array.from(namespaces).sort(collator.compare);
    } finally {
      client.disconnect();
    }
  }

  private validateResource(name: string): void {
    if (!RESOURCE_REGEX.test(name)) {
      throw new BadRequestException(`Invalid Redis resource key: ${name}`);
    }
  }

  private async connect(connectionString: string): Promise<Redis> {
    const client = new IORedis(connectionString, {
      lazyConnect: true,
      maxRetriesPerRequest: 2,
      enableOfflineQueue: false,
      connectTimeout: 5_000,
    });
    await client.connect();
    return client;
  }

  /** Build the per-user namespaced prefix for a resource. */
  private prefix(resource: string, userId?: string): string {
    return userId ? `${userId}:${resource}` : resource;
  }

  private hashFromRecord(data: Record<string, unknown>): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(data)) {
      if (v === undefined || v === null) continue;
      out[k] = typeof v === 'string' ? v : JSON.stringify(v);
    }
    return out;
  }

  private recordFromHash(hash: Record<string, string>): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(hash)) {
      try {
        out[k] = JSON.parse(v);
      } catch {
        out[k] = v;
      }
    }
    return out;
  }

  private idFromValue(value: unknown): string {
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      return String(value).trim();
    }
    throw new BadRequestException('Redis id must be a string, number, or boolean');
  }

  private async list(client: Redis, resource: string, opts: QueryOpts): Promise<QueryResult> {
    const prefix = this.prefix(resource, opts.userId);
    const limit = Math.min(opts.limit ?? 100, 500);
    const offset = Math.max(0, opts.offset ?? 0);

    const collected: string[] = [];
    let cursor = '0';
    do {
      const [next, keys] = await client.scan(cursor, 'MATCH', `${prefix}:*`, 'COUNT', 200);
      cursor = next;
      for (const k of keys) collected.push(k);
      if (collected.length >= limit + offset) break;
    } while (cursor !== '0');

    const sorted = [...collected].sort((left, right) => left.localeCompare(right));
    const slice = sorted.slice(offset, offset + limit);
    if (!slice.length) return { rows: [], rowCount: 0 };

    const pipeline = client.pipeline();
    for (const k of slice) pipeline.hgetall(k);
    const results = (await pipeline.exec()) ?? [];

    const rows: Record<string, unknown>[] = [];
    for (let i = 0; i < results.length; i++) {
      const [err, hash] = results[i] as [Error | null, Record<string, string>];
      if (err || !hash) continue;
      const key = slice[i];
      const id = key.slice(prefix.length + 1);
      rows.push({ id, ...this.recordFromHash(hash) });
    }
    return { rows, rowCount: rows.length };
  }

  private async get(client: Redis, resource: string, opts: QueryOpts): Promise<QueryResult> {
    const idValue = opts.filter?.['id'] ?? opts.data?.['id'];
    const id = idValue === undefined || idValue === null ? '' : this.idFromValue(idValue);
    if (!id) throw new BadRequestException('Redis get requires filter.id or data.id');

    const key = `${this.prefix(resource, opts.userId)}:${id}`;
    const hash = await client.hgetall(key);
    if (!hash || Object.keys(hash).length === 0) {
      return { rows: [], rowCount: 0 };
    }
    return { rows: [{ id, ...this.recordFromHash(hash) }], rowCount: 1 };
  }

  private async insert(client: Redis, resource: string, opts: QueryOpts): Promise<QueryResult> {
    if (!opts.data) throw new BadRequestException('data is required for insert');
    const { id: rawId, ...rest } = opts.data as Record<string, unknown>;
    const id = rawId === undefined || rawId === null ? this.generateId() : this.idFromValue(rawId);
    const key = `${this.prefix(resource, opts.userId)}:${id}`;

    const exists = await client.exists(key);
    if (exists) throw new BadRequestException(`Redis key already exists: ${key}`);

    const hash = this.hashFromRecord(rest);
    if (Object.keys(hash).length > 0) await client.hset(key, hash);
    return { rows: [{ id, ...rest }], rowCount: 1 };
  }

  private async update(client: Redis, resource: string, opts: QueryOpts): Promise<QueryResult> {
    if (!opts.data) throw new BadRequestException('data is required for update');
    const idValue = opts.filter?.['id'] ?? (opts.data as Record<string, unknown>)['id'];
    const id = idValue === undefined || idValue === null ? '' : this.idFromValue(idValue);
    if (!id) throw new BadRequestException('Redis update requires filter.id');
    const key = `${this.prefix(resource, opts.userId)}:${id}`;

    const exists = await client.exists(key);
    if (!exists) return { rows: [], rowCount: 0 };

    const { id: _drop, ...rest } = opts.data as Record<string, unknown>;
    const hash = this.hashFromRecord(rest);
    if (Object.keys(hash).length > 0) await client.hset(key, hash);
    return { rows: [{ id, ...rest }], rowCount: 1 };
  }

  private async delete(client: Redis, resource: string, opts: QueryOpts): Promise<QueryResult> {
    const idValue = opts.filter?.['id'];
    const id = idValue === undefined || idValue === null ? '' : this.idFromValue(idValue);
    if (!id) throw new BadRequestException('Redis delete requires filter.id');
    const key = `${this.prefix(resource, opts.userId)}:${id}`;
    const removed = await client.del(key);
    return { rows: [], rowCount: removed };
  }

  private async upsert(client: Redis, resource: string, opts: QueryOpts): Promise<QueryResult> {
    if (!opts.data) throw new BadRequestException('data is required for upsert');
    const { id: rawId, ...rest } = opts.data as Record<string, unknown>;
    const id = rawId === undefined || rawId === null ? this.generateId() : this.idFromValue(rawId);
    const key = `${this.prefix(resource, opts.userId)}:${id}`;

    const hash = this.hashFromRecord(rest);
    if (Object.keys(hash).length > 0) await client.hset(key, hash);
    return { rows: [{ id, ...rest }], rowCount: 1 };
  }

  private generateId(): string {
    // Compact monotonic id good enough for KV semantics.
    return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  }
}

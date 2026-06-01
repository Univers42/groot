/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   postgresql.engine.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:41:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  BadRequestException,
  Injectable,
  NotImplementedException,
} from '@nestjs/common';
import { Client } from 'pg';
import type {
  AdapterOp,
  EngineCaps,
  IDatabaseAdapter,
  QueryOpts,
  QueryResult,
} from '@mini-baas/database';

const TABLE_REGEX = /^[a-zA-Z_]\w{0,63}$/;
const COLUMN_REGEX = /^[a-zA-Z_]\w*$/;

@Injectable()
export class PostgresqlEngine implements IDatabaseAdapter {
  readonly engine = 'postgresql';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: false,
      txIntra: true,
      stream: false,
      semantic: { joins: 'native', patternSearch: 'native', ddl: true, migrationVersioning: true, latencyClass: 'native' },
    };
  }

  async execute(
    connectionString: string,
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Promise<QueryResult> {
    this.validateTable(resource);

    const client = new Client({ connectionString });
    await client.connect();

    try {
      // Set user context so unified RLS policies can enforce row-level isolation.
      if (opts.userId) {
        await client.query('BEGIN');
        await client.query(
          `SELECT set_config('app.current_user_id', $1, true), set_config('request.jwt.claims', $2, true)`,
          [opts.userId, JSON.stringify({ sub: opts.userId })],
        );
      }

      let result: QueryResult;
      switch (op) {
        case 'list':
          result = await this.select(client, resource, opts);
          break;
        case 'get':
          result = await this.select(client, resource, { ...opts, limit: 1 });
          break;
        case 'insert':
          result = await this.insert(client, resource, opts.data ?? {}, opts.userId);
          break;
        case 'update':
          result = await this.update(client, resource, opts.data ?? {}, opts.filter ?? {});
          break;
        case 'delete':
          result = await this.deleteRows(client, resource, opts.filter ?? {});
          break;
        case 'upsert':
          throw new NotImplementedException(
            'PostgreSQL upsert is reserved for M2 — use insert + ON CONFLICT directly via schema-service migrations for now.',
          );
        default:
          throw new BadRequestException(`Unknown operation: ${op}`);
      }

      if (opts.userId) {
        await client.query('COMMIT');
      }
      return result;
    } catch (err) {
      if (opts.userId) {
        await client.query('ROLLBACK').catch(() => {});
      }
      throw err;
    } finally {
      await client.end();
    }
  }

  async listResources(connectionString: string): Promise<string[]> {
    const client = new Client({ connectionString });
    await client.connect();
    try {
      const res = await client.query(
        `SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name`,
      );
      return res.rows.map((r) => r['table_name'] as string);
    } finally {
      await client.end();
    }
  }

  private validateTable(name: string): void {
    if (!TABLE_REGEX.test(name)) {
      throw new BadRequestException(`Invalid table name: ${name}`);
    }
  }

  private validateColumn(name: string): void {
    if (!COLUMN_REGEX.test(name)) {
      throw new BadRequestException(`Invalid column name: ${name}`);
    }
  }

  private async select(
    client: Client,
    table: string,
    opts: Pick<QueryOpts, 'filter' | 'sort' | 'limit' | 'offset'>,
  ): Promise<QueryResult> {
    const params: unknown[] = [];
    let sql = `SELECT * FROM "${table}"`;

    const where = this.buildWhere(opts.filter ?? {}, params);
    if (where) sql += ` WHERE ${where}`;

    if (opts.sort) {
      const orderParts: string[] = [];
      for (const [col, dir] of Object.entries(opts.sort)) {
        this.validateColumn(col);
        orderParts.push(`"${col}" ${String(dir).toUpperCase() === 'ASC' ? 'ASC' : 'DESC'}`);
      }
      if (orderParts.length) sql += ` ORDER BY ${orderParts.join(', ')}`;
    }

    const limit = Math.min(opts.limit ?? 100, 500);
    params.push(limit);
    sql += ` LIMIT $${params.length}`;

    if (opts.offset) {
      params.push(opts.offset);
      sql += ` OFFSET $${params.length}`;
    }

    const res = await client.query(sql, params);
    return { rows: res.rows as Record<string, unknown>[], rowCount: res.rowCount ?? 0 };
  }

  private async insert(
    client: Client,
    table: string,
    data: Record<string, unknown>,
    userId?: string,
  ): Promise<QueryResult> {
    const enriched = { ...data };
    if (userId && !enriched['owner_id']) {
      enriched['owner_id'] = userId;
    }

    const cols = Object.keys(enriched);
    if (!cols.length) throw new BadRequestException('No data to insert');
    cols.forEach((c) => this.validateColumn(c));

    const placeholders = cols.map((_, i) => `$${i + 1}`);
    const quotedColumns = cols.map((c) => `"${c}"`).join(', ');
    const sql = `INSERT INTO "${table}" (${quotedColumns}) VALUES (${placeholders.join(', ')}) RETURNING *`;

    const res = await client.query(sql, Object.values(enriched));
    return { rows: res.rows as Record<string, unknown>[], rowCount: res.rowCount ?? 0 };
  }

  private async update(
    client: Client,
    table: string,
    data: Record<string, unknown>,
    filter: Record<string, unknown>,
  ): Promise<QueryResult> {
    const setCols = Object.keys(data);
    if (!setCols.length) throw new BadRequestException('No data to update');
    setCols.forEach((c) => this.validateColumn(c));

    const params: unknown[] = [];
    const setParts = setCols.map((col) => {
      params.push(data[col]);
      return `"${col}" = $${params.length}`;
    });

    let sql = `UPDATE "${table}" SET ${setParts.join(', ')}`;

    const where = this.buildWhere(filter, params);
    if (where) sql += ` WHERE ${where}`;

    sql += ' RETURNING *';

    const res = await client.query(sql, params);
    return { rows: res.rows as Record<string, unknown>[], rowCount: res.rowCount ?? 0 };
  }

  private async deleteRows(
    client: Client,
    table: string,
    filter: Record<string, unknown>,
  ): Promise<QueryResult> {
    const params: unknown[] = [];
    let sql = `DELETE FROM "${table}"`;

    const where = this.buildWhere(filter, params);
    if (where) sql += ` WHERE ${where}`;

    sql += ' RETURNING *';

    const res = await client.query(sql, params);
    return { rows: res.rows as Record<string, unknown>[], rowCount: res.rowCount ?? 0 };
  }

  private buildWhere(filter: Record<string, unknown>, params: unknown[]): string {
    const conditions: string[] = [];
    for (const [col, val] of Object.entries(filter)) {
      this.validateColumn(col);
      params.push(val);
      conditions.push(`"${col}" = $${params.length}`);
    }
    return conditions.join(' AND ');
  }
}

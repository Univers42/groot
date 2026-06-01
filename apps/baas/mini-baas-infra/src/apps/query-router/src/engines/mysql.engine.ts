/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mysql.engine.ts                                    :+:      :+:    :+:   */
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
import mysql, {
  type Connection,
  type RowDataPacket,
  type ResultSetHeader,
} from 'mysql2/promise';

const TABLE_REGEX = /^[a-zA-Z_]\w{0,63}$/;
const COLUMN_REGEX = /^[a-zA-Z_]\w*$/;
type MysqlParam = string | number | boolean | Date | Buffer | null;

/**
 * MySQL adapter (M2 federation).
 *
 * Uses `mysql2/promise` parameterized queries throughout — no string
 * concatenation, identifier names validated via regex. Owner isolation is
 * applied at the query-router level by injecting `owner_id` into INSERT
 * payloads and filtering on it for read / update / delete operations.
 *
 * Native `upsert` is supported via `INSERT ... ON DUPLICATE KEY UPDATE`.
 */
@Injectable()
export class MysqlEngine implements IDatabaseAdapter {
  readonly engine = 'mysql';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: true,
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

    const connection = await mysql.createConnection(connectionString);

    try {
      if (opts.userId) await connection.beginTransaction();

      let result: QueryResult;
      switch (op) {
        case 'list':
          result = await this.select(connection, resource, opts);
          break;
        case 'get':
          result = await this.select(connection, resource, { ...opts, limit: 1 });
          break;
        case 'insert':
          result = await this.insert(connection, resource, opts.data ?? {}, opts.userId);
          break;
        case 'update':
          result = await this.update(connection, resource, opts.data ?? {}, opts.filter ?? {}, opts.userId);
          break;
        case 'delete':
          result = await this.deleteRows(connection, resource, opts.filter ?? {}, opts.userId);
          break;
        case 'upsert':
          result = await this.upsert(connection, resource, opts.data ?? {}, opts.userId);
          break;
        default:
          throw new NotImplementedException(`MySQL adapter does not implement op '${op}'`);
      }

      if (opts.userId) await connection.commit();
      return result;
    } catch (err) {
      if (opts.userId) await connection.rollback().catch(() => undefined);
      throw err;
    } finally {
      await connection.end().catch(() => undefined);
    }
  }

  async listResources(connectionString: string): Promise<string[]> {
    const connection = await mysql.createConnection(connectionString);
    try {
      const [rows] = await connection.query<RowDataPacket[]>(
        `SELECT table_name AS name
           FROM information_schema.tables
          WHERE table_schema = DATABASE()
            AND table_type = 'BASE TABLE'
          ORDER BY table_name`,
      );
      return rows.map((r) => String(r['name'] ?? r['TABLE_NAME'] ?? ''));
    } finally {
      await connection.end().catch(() => undefined);
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

  private buildWhere(
    filter: Record<string, unknown>,
    params: MysqlParam[],
    userId?: string,
  ): string {
    const conditions: string[] = [];
    const fullFilter = { ...filter };
    if (userId && !('owner_id' in fullFilter)) {
      fullFilter['owner_id'] = userId;
    }
    for (const [col, val] of Object.entries(fullFilter)) {
      this.validateColumn(col);
      params.push(this.toParam(val));
      conditions.push(`\`${col}\` = ?`);
    }
    return conditions.join(' AND ');
  }

  private toParam(value: unknown): MysqlParam {
    if (value === undefined || value === null) return null;
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      return value;
    }
    if (value instanceof Date || Buffer.isBuffer(value)) return value;
    return JSON.stringify(value);
  }

  private async select(
    connection: Connection,
    table: string,
    opts: Pick<QueryOpts, 'filter' | 'sort' | 'limit' | 'offset' | 'userId'>,
  ): Promise<QueryResult> {
    const params: MysqlParam[] = [];
    let sql = `SELECT * FROM \`${table}\``;
    const where = this.buildWhere(opts.filter ?? {}, params, opts.userId);
    if (where) sql += ` WHERE ${where}`;

    if (opts.sort) {
      const orderParts: string[] = [];
      for (const [col, dir] of Object.entries(opts.sort)) {
        this.validateColumn(col);
        orderParts.push(`\`${col}\` ${dir === 'asc' ? 'ASC' : 'DESC'}`);
      }
      if (orderParts.length) sql += ` ORDER BY ${orderParts.join(', ')}`;
    }

    const limit = Math.min(opts.limit ?? 100, 500);
    sql += ` LIMIT ${limit}`;
    if (opts.offset) sql += ` OFFSET ${Math.max(0, Math.floor(opts.offset))}`;

    const [rows] = await connection.query<RowDataPacket[]>(sql, params);
    return { rows: rows as Record<string, unknown>[], rowCount: rows.length };
  }

  private async insert(
    connection: Connection,
    table: string,
    data: Record<string, unknown>,
    userId?: string,
  ): Promise<QueryResult> {
    const enriched = { ...data };
    if (userId && !enriched['owner_id']) enriched['owner_id'] = userId;

    const cols = Object.keys(enriched);
    if (!cols.length) throw new BadRequestException('No data to insert');
    cols.forEach((c) => this.validateColumn(c));

    const placeholders = cols.map(() => '?').join(', ');
    const quoted = cols.map((c) => `\`${c}\``).join(', ');
    const sql = `INSERT INTO \`${table}\` (${quoted}) VALUES (${placeholders})`;

    const values = cols.map((col) => this.toParam(enriched[col]));
    const [res] = await connection.execute<ResultSetHeader>(sql, values);
    return {
      rows: [{ ...enriched, id: res.insertId ?? null }],
      rowCount: res.affectedRows ?? 1,
    };
  }

  private async update(
    connection: Connection,
    table: string,
    data: Record<string, unknown>,
    filter: Record<string, unknown>,
    userId?: string,
  ): Promise<QueryResult> {
    const cols = Object.keys(data);
    if (!cols.length) throw new BadRequestException('No data to update');
    cols.forEach((c) => this.validateColumn(c));

    const params: MysqlParam[] = [];
    const setParts = cols.map((col) => {
      params.push(this.toParam(data[col]));
      return `\`${col}\` = ?`;
    });

    let sql = `UPDATE \`${table}\` SET ${setParts.join(', ')}`;
    const where = this.buildWhere(filter, params, userId);
    if (where) sql += ` WHERE ${where}`;

    const [res] = await connection.execute<ResultSetHeader>(sql, params);
    return { rows: [], rowCount: res.affectedRows ?? 0 };
  }

  private async deleteRows(
    connection: Connection,
    table: string,
    filter: Record<string, unknown>,
    userId?: string,
  ): Promise<QueryResult> {
    const params: MysqlParam[] = [];
    let sql = `DELETE FROM \`${table}\``;
    const where = this.buildWhere(filter, params, userId);
    if (where) sql += ` WHERE ${where}`;

    const [res] = await connection.execute<ResultSetHeader>(sql, params);
    return { rows: [], rowCount: res.affectedRows ?? 0 };
  }

  private async upsert(
    connection: Connection,
    table: string,
    data: Record<string, unknown>,
    userId?: string,
  ): Promise<QueryResult> {
    const enriched = { ...data };
    if (userId && !enriched['owner_id']) enriched['owner_id'] = userId;

    const cols = Object.keys(enriched);
    if (!cols.length) throw new BadRequestException('No data to upsert');
    cols.forEach((c) => this.validateColumn(c));

    const placeholders = cols.map(() => '?').join(', ');
    const quoted = cols.map((c) => `\`${c}\``).join(', ');
    const updates = cols.map((c) => `\`${c}\` = VALUES(\`${c}\`)`).join(', ');
    const sql =
      `INSERT INTO \`${table}\` (${quoted}) VALUES (${placeholders}) ` +
      `ON DUPLICATE KEY UPDATE ${updates}`;

    const values = cols.map((col) => this.toParam(enriched[col]));
    const [res] = await connection.execute<ResultSetHeader>(sql, values);
    return {
      rows: [{ ...enriched, id: res.insertId ?? null }],
      rowCount: res.affectedRows ?? 1,
    };
  }
}

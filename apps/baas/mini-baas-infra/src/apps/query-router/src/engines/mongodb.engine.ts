/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mongodb.engine.ts                                  :+:      :+:    :+:   */
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
import { Collection, MongoClient } from 'mongodb';
import type {
  AdapterOp,
  EngineCaps,
  IDatabaseAdapter,
  QueryOpts,
  QueryResult,
} from '@mini-baas/database';

const COLLECTION_REGEX = /^[\w-]{1,64}$/;

@Injectable()
export class MongodbEngine implements IDatabaseAdapter {
  readonly engine = 'mongodb';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: false,
      txIntra: false,
      stream: true,
      semantic: { joins: 'limited', patternSearch: 'indexed', ddl: true, migrationVersioning: true, latencyClass: 'native' },
    };
  }

  async execute(
    connectionString: string,
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Promise<QueryResult> {
    this.validateCollection(resource);

    const dbName = this.extractDbName(connectionString);

    const client = new MongoClient(connectionString, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await client.connect();

    try {
      const col = client.db(dbName).collection(resource);

      switch (op) {
        case 'list':
          return await this.find(col, opts);
        case 'get':
          return await this.find(col, { ...opts, limit: 1 });
        case 'insert':
          return await this.insertOne(col, opts);
        case 'update':
          return await this.updateMany(col, opts);
        case 'delete':
          return await this.deleteMany(col, opts);
        case 'upsert':
          throw new NotImplementedException(
            'MongoDB upsert is reserved for M2 — use update with explicit upsert flag from schema-service for now.',
          );
        default:
          throw new BadRequestException(`Unknown operation: ${op}`);
      }
    } finally {
      await client.close();
    }
  }

  async listResources(connectionString: string, dbName?: string): Promise<string[]> {
    const resolvedDb = dbName ?? this.extractDbName(connectionString);
    const client = new MongoClient(connectionString, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await client.connect();
    try {
      const cols = await client.db(resolvedDb).listCollections().toArray();
      return cols.map((c) => c.name);
    } finally {
      await client.close();
    }
  }

  private extractDbName(connectionString: string): string {
    try {
      const url = new URL(connectionString);
      const path = url.pathname.replace(/^\//, '');
      return path || 'test';
    } catch {
      return 'test';
    }
  }

  private validateCollection(name: string): void {
    if (!COLLECTION_REGEX.test(name)) {
      throw new BadRequestException(`Invalid collection name: ${name}`);
    }
  }

  private normalizeDoc(doc: Record<string, unknown>): Record<string, unknown> {
    const { _id, ...rest } = doc;
    return { id: String(_id), ...rest };
  }

  private cloneFilter(filter?: Record<string, unknown>): Record<string, unknown> {
    return filter ? { ...filter } : {};
  }

  private applyOwnerFilter(
    filter: Record<string, unknown>,
    userId?: string,
  ): Record<string, unknown> {
    if (userId) {
      filter['owner_id'] = userId;
    }
    return filter;
  }

  private buildSort(
    sortInput?: Record<string, 'asc' | 'desc'>,
  ): Record<string, 1 | -1> | undefined {
    if (!sortInput) return undefined;
    return Object.fromEntries(
      Object.entries(sortInput).map(([field, dir]) => [
        field,
        String(dir).toLowerCase() === 'asc' ? 1 : -1,
      ]),
    );
  }

  private async find(col: Collection, opts: QueryOpts): Promise<QueryResult> {
    const filter = this.applyOwnerFilter(this.cloneFilter(opts.filter), opts.userId);
    delete filter['$where'];

    const limit = Math.min(opts.limit ?? 100, 500);
    let cursor = col.find(filter).skip(opts.offset ?? 0).limit(limit);
    const sort = this.buildSort(opts.sort);
    if (sort) cursor = cursor.sort(sort);

    const docs = await cursor.toArray();
    return {
      rows: docs.map((d) => this.normalizeDoc(d as Record<string, unknown>)),
      rowCount: docs.length,
    };
  }

  private async insertOne(col: Collection, opts: QueryOpts): Promise<QueryResult> {
    if (!opts.data) throw new BadRequestException('data is required for insert');
    const { _id: _, owner_id: __, ...clean } = opts.data;
    const doc: Record<string, unknown> = {
      ...clean,
      created_at: new Date(),
      updated_at: new Date(),
    };
    if (opts.userId) doc['owner_id'] = opts.userId;
    const result = await col.insertOne(doc);
    return {
      rows: [{ id: result.insertedId.toString(), ...doc }],
      rowCount: 1,
    };
  }

  private async updateMany(col: Collection, opts: QueryOpts): Promise<QueryResult> {
    if (!opts.data) throw new BadRequestException('data is required for update');
    const { _id: _, owner_id: __, ...cleanData } = opts.data;
    const updateFilter = this.applyOwnerFilter(this.cloneFilter(opts.filter), opts.userId);
    const result = await col.updateMany(updateFilter, {
      $set: { ...cleanData, updated_at: new Date() },
    });
    return { rows: [], rowCount: result.modifiedCount };
  }

  private async deleteMany(col: Collection, opts: QueryOpts): Promise<QueryResult> {
    const deleteFilter = this.applyOwnerFilter(this.cloneFilter(opts.filter), opts.userId);
    const result = await col.deleteMany(deleteFilter);
    return { rows: [], rowCount: result.deletedCount };
  }
}

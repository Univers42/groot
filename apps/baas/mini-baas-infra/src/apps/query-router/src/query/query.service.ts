/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  Logger,
  OnModuleInit,
  ServiceUnavailableException,
} from '@nestjs/common';
import { ModuleRef } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import type { EngineCaps, IDatabaseAdapter, QueryResult } from '@mini-baas/database';
import { PostgresqlEngine } from '../engines/postgresql.engine';
import { MongodbEngine } from '../engines/mongodb.engine';
import { MysqlEngine } from '../engines/mysql.engine';
import { RedisEngine } from '../engines/redis.engine';
import { HttpEngine } from '../engines/http.engine';
import { JdbcEngine } from '../engines/jdbc.engine';
import { CassandraEngine } from '../engines/cassandra.engine';
import { Neo4jEngine } from '../engines/neo4j.engine';
import { ElasticsearchEngine } from '../engines/elasticsearch.engine';
import { QdrantEngine } from '../engines/qdrant.engine';
import { InfluxEngine } from '../engines/influx.engine';
import { ExecuteQueryDto } from './dto/query.dto';
import { OutboxService } from './outbox.service';

interface AdapterResponse {
  engine: string;
  connection_string: string;
}

export interface EngineDescriptor {
  engine: string;
  capabilities: EngineCaps;
}

interface QueryRequestContext {
  requestId?: string;
}

interface FieldMask {
  hide?: string[];
  redact?: Record<string, string>;
}

interface PermissionDecision {
  allow: boolean;
  reason: string;
  mask?: FieldMask;
}

@Injectable()
export class QueryService implements OnModuleInit {
  private readonly logger = new Logger(QueryService.name);
  private readonly registryUrl: string;
  private readonly permissionUrl: string;
  private readonly serviceToken: string;
  private readonly controlPlaneTimeoutMs: number;
  private readonly adapters = new Map<string, IDatabaseAdapter>();

  constructor(
    private readonly config: ConfigService,
    private readonly http: HttpService,
    private readonly moduleRef: ModuleRef,
    private readonly outbox: OutboxService,
  ) {
    this.registryUrl = this.config.getOrThrow<string>('ADAPTER_REGISTRY_URL');
    this.permissionUrl = this.config.get<string>('PERMISSION_ENGINE_URL', 'http://permission-engine:3050');
    this.serviceToken = this.config.get<string>('ADAPTER_REGISTRY_SERVICE_TOKEN', '');
    this.controlPlaneTimeoutMs = this.config.get<number>('CONTROL_PLANE_TIMEOUT_MS', 2_000);
  }

  onModuleInit(): void {
    this.registerAdapters();
  }

  private registerAdapters(): void {
    if (this.adapters.size > 0) return;
    const adapterTypes = [
      PostgresqlEngine,
      MongodbEngine,
      MysqlEngine,
      RedisEngine,
      HttpEngine,
      JdbcEngine,
      CassandraEngine,
      Neo4jEngine,
      ElasticsearchEngine,
      QdrantEngine,
      InfluxEngine,
    ];
    for (const adapterType of adapterTypes) {
      const adapter = this.moduleRef.get<IDatabaseAdapter>(adapterType, { strict: false });
      this.adapters.set(adapter.engine, adapter);
    }
    this.logger.log(
      `Registered ${this.adapters.size} engines: ${Array.from(this.adapters.keys()).join(', ')}`,
    );
  }

  /** Static introspection of every adapter currently mounted on this service. */
  listEngines(): EngineDescriptor[] {
    this.registerAdapters();
    return Array.from(this.adapters.values()).map((a) => ({
      engine: a.engine,
      capabilities: a.capabilities(),
    }));
  }

  private async fetchConnection(dbId: string, userId: string): Promise<AdapterResponse> {
    const url = `${this.registryUrl}/databases/${dbId}/connect`;
    const { data } = await firstValueFrom(
      this.http.get<AdapterResponse>(url, {
        headers: {
          'X-Service-Token': this.serviceToken,
          'X-Tenant-Id': userId,
        },
      }),
    );
    return data;
  }

  private resolveAdapter(engine: string): IDatabaseAdapter {
    this.registerAdapters();
    const adapter = this.adapters.get(engine);
    if (!adapter) {
      throw new BadRequestException(
        `Unsupported engine '${engine}'. Registered engines: ${Array.from(this.adapters.keys()).join(', ')}`,
      );
    }
    return adapter;
  }

  async executeQuery(
    dbId: string,
    resource: string,
    userId: string,
    dto: ExecuteQueryDto,
    context: QueryRequestContext = {},
  ) {
    const op = dto.resolveOp();
    if (!op) {
      throw new BadRequestException(
        'Missing operation: provide `op` (preferred) or the deprecated `action` field.',
      );
    }

    const { engine, connection_string } = await this.fetchConnection(dbId, userId);
    const adapter = this.resolveAdapter(engine);
    const decision = await this.decidePermission(userId, engine, resource, op, context);
    if (!decision.allow) {
      throw new ForbiddenException(decision.reason);
    }

    if (dto.action && !dto.op) {
      this.logger.warn(
        `[deprecated] action='${dto.action}' received — switch to op='${op}' before the next minor release.`,
      );
    }

    const result = await adapter.execute(connection_string, resource, op, {
      data: dto.data,
      filter: dto.filter,
      sort: dto.sort,
      limit: dto.limit,
      offset: dto.offset,
      userId,
      idempotencyKey: dto.idempotencyKey,
    });

    await this.outbox
      .emitForQuery({
        engine,
        resource,
        op,
        result,
        data: dto.data,
        filter: dto.filter,
        requestId: context.requestId,
        actorId: userId,
        idempotencyKey: dto.idempotencyKey,
      })
      .catch((error: Error) => {
        this.logger.warn(`outbox emission failed for ${engine}.${resource}.${op}: ${error.message}`);
      });

    return this.applyFieldMask(result, decision.mask);
  }

  private async decidePermission(
    userId: string,
    engine: string,
    resource: string,
    op: string,
    context: QueryRequestContext,
  ): Promise<PermissionDecision> {
    try {
      const { data } = await firstValueFrom(
        this.http.post<PermissionDecision>(
          `${this.permissionUrl}/permissions/decide`,
          {
            user: { id: userId },
            resource_type: engine,
            resource_name: resource,
            op,
            attributes: { request_id: context.requestId },
          },
          {
            timeout: this.controlPlaneTimeoutMs,
            headers: {
              'X-Service-Token': this.serviceToken,
              'X-Tenant-Id': userId,
            },
          },
        ),
      );
      return data;
    } catch (error) {
      throw new ServiceUnavailableException(
        `ABAC decision service failed closed: ${error instanceof Error ? error.message : 'unknown error'}`,
      );
    }
  }

  private applyFieldMask(result: QueryResult, mask: FieldMask | undefined): QueryResult {
    if (!mask) return result;
    const hidden = new Set(mask.hide ?? []);
    const redact = mask.redact ?? {};
    return {
      rowCount: result.rowCount,
      rows: result.rows.map((row) => {
        const masked: Record<string, unknown> = { ...row };
        for (const field of hidden) delete masked[field];
        for (const [field, replacement] of Object.entries(redact)) {
          if (field in masked) masked[field] = replacement;
        }
        return masked;
      }),
    };
  }

  async listTables(dbId: string, userId: string) {
    const { engine, connection_string } = await this.fetchConnection(dbId, userId);
    const adapter = this.resolveAdapter(engine);
    const resources = await adapter.listResources(connection_string);

    // Per-engine response key kept for back-compat with existing clients that
    // looked for `.tables` (SQL) or `.collections` (Mongo). New engines only
    // expose `.resources` — clients should migrate to that key.
    const legacyKey = RESOURCE_KEY_BY_ENGINE[engine];
    if (legacyKey) {
      return { engine, [legacyKey]: resources, resources };
    }
    return { engine, resources };
  }
}

const RESOURCE_KEY_BY_ENGINE: Readonly<Record<string, string>> = Object.freeze({
  postgresql: 'tables',
  mongodb: 'collections',
  mysql: 'tables',
  jdbc: 'resources',
  cassandra: 'tables',
  neo4j: 'labels',
  elasticsearch: 'indices',
  qdrant: 'collections',
  influx: 'measurements',
});

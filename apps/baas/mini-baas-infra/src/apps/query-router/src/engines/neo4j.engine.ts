import { BadRequestException, Injectable } from '@nestjs/common';
import type { AdapterOp, EngineCaps, IDatabaseAdapter, QueryOpts, QueryResult } from '@mini-baas/database';
import { fetchJson, getRequiredId, parseRemoteConnection, queryResultFromRows, rowsFromUnknown, scalarString, validateResourceName, withOwner } from './remote-engine-utils';

@Injectable()
export class Neo4jEngine implements IDatabaseAdapter {
  readonly engine = 'neo4j';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: true,
      txIntra: true,
      stream: false,
      semantic: { joins: 'limited', patternSearch: 'native', ddl: false, migrationVersioning: false, latencyClass: 'adapter' },
    };
  }

  async execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult> {
    validateResourceName(resource, 'Neo4j');
    const conn = parseRemoteConnection(connectionString);
    const label = resource.replace(/\W/g, '_');
    const database = conn.database ?? 'neo4j';
    const ownerClause = opts.userId ? 'ownerId: $ownerId' : '';
    const data = withOwner(opts.data, opts);

    let statement: string;
    const parameters: Record<string, unknown> = { data, ownerId: opts.userId, id: opts.filter?.['id'] ?? opts.data?.['id'], limit: Math.min(opts.limit ?? 100, 500) };
    switch (op) {
      case 'list':
        statement = `MATCH (n:${label} {${ownerClause}}) RETURN n LIMIT $limit`;
        break;
      case 'get':
        statement = `MATCH (n:${label} {id: $id${opts.userId ? ', ownerId: $ownerId' : ''}}) RETURN n LIMIT 1`;
        parameters.id = getRequiredId(opts, op);
        break;
      case 'insert':
        statement = `CREATE (n:${label}) SET n = $data RETURN n`;
        break;
      case 'update':
        parameters.id = getRequiredId(opts, op);
        statement = `MATCH (n:${label} {id: $id${opts.userId ? ', ownerId: $ownerId' : ''}}) SET n += $data RETURN n`;
        break;
      case 'delete':
        parameters.id = getRequiredId(opts, op);
        statement = `MATCH (n:${label} {id: $id${opts.userId ? ', ownerId: $ownerId' : ''}}) DETACH DELETE n RETURN count(n) AS deleted`;
        break;
      case 'upsert':
        parameters.id = getRequiredId(opts, op);
        statement = `MERGE (n:${label} {id: $id${opts.userId ? ', ownerId: $ownerId' : ''}}) SET n += $data RETURN n`;
        break;
      default:
        throw new BadRequestException(`Unknown operation: ${op}`);
    }

    const json = await fetchJson(conn, `/db/${encodeURIComponent(database)}/tx/commit`, {
      method: 'POST',
      body: { statements: [{ statement, parameters }] },
    });
    return queryResultFromRows(this.rowsFromNeo4j(json));
  }

  async listResources(connectionString: string): Promise<string[]> {
    const conn = parseRemoteConnection(connectionString);
    const database = conn.database ?? 'neo4j';
    const json = await fetchJson(conn, `/db/${encodeURIComponent(database)}/tx/commit`, {
      method: 'POST',
      body: { statements: [{ statement: 'CALL db.labels() YIELD label RETURN label' }] },
    });
    return this.rowsFromNeo4j(json)
      .map((row) => scalarString(row['label']))
      .filter((label): label is string => !!label);
  }

  private rowsFromNeo4j(json: unknown): Record<string, unknown>[] {
    const rows = rowsFromUnknown(json);
    if (rows.length) return rows;
    const result = json as { results?: Array<{ data?: Array<{ row?: unknown[] }> }> };
    return result.results?.flatMap((entry) => entry.data?.map((data) => ({ row: data.row ?? [] })) ?? []) ?? [];
  }
}
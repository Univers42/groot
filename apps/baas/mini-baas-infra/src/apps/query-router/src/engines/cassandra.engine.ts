import { BadRequestException, Injectable } from '@nestjs/common';
import type { AdapterOp, EngineCaps, IDatabaseAdapter, QueryOpts, QueryResult } from '@mini-baas/database';
import { fetchJson, getRequiredId, parseRemoteConnection, queryResultFromRows, rowsFromUnknown, scalarString, validateResourceName, withOwner } from './remote-engine-utils';

@Injectable()
export class CassandraEngine implements IDatabaseAdapter {
  readonly engine = 'cassandra';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: true,
      txIntra: false,
      stream: true,
      semantic: { joins: 'none', patternSearch: 'limited', ddl: false, migrationVersioning: false, latencyClass: 'adapter' },
    };
  }

  async execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult> {
    validateResourceName(resource, 'Cassandra');
    const conn = parseRemoteConnection(connectionString);
    const keyspace = conn.keyspace ?? conn.database;
    if (!keyspace) throw new BadRequestException('Cassandra connection_string requires keyspace');
    const tablePath = `/v2/keyspaces/${encodeURIComponent(keyspace)}/${encodeURIComponent(resource)}`;

    switch (op) {
      case 'list':
      case 'get': {
        const where = opts.userId ? `?where=${encodeURIComponent(JSON.stringify({ ownerId: { $eq: opts.userId } }))}` : '';
        const json = await fetchJson(conn, `${tablePath}${where}`);
        const rows = rowsFromUnknown(json).slice(opts.offset ?? 0, (opts.offset ?? 0) + Math.min(opts.limit ?? 100, 500));
        return queryResultFromRows(op === 'get' ? rows.slice(0, 1) : rows);
      }
      case 'insert':
      case 'upsert': {
        const json = await fetchJson(conn, tablePath, { method: 'POST', body: withOwner(opts.data, opts) });
        return queryResultFromRows(rowsFromUnknown(json));
      }
      case 'update': {
        const id = getRequiredId(opts, op);
        const json = await fetchJson(conn, `${tablePath}/${encodeURIComponent(id)}`, { method: 'PUT', body: withOwner(opts.data, opts) });
        return queryResultFromRows(rowsFromUnknown(json));
      }
      case 'delete': {
        const id = getRequiredId(opts, op);
        await fetchJson(conn, `${tablePath}/${encodeURIComponent(id)}`, { method: 'DELETE' });
        return { rows: [], rowCount: 1 };
      }
      default:
        throw new BadRequestException(`Unknown operation: ${op}`);
    }
  }

  async listResources(connectionString: string): Promise<string[]> {
    const conn = parseRemoteConnection(connectionString);
    const keyspace = conn.keyspace ?? conn.database;
    if (!keyspace) throw new BadRequestException('Cassandra connection_string requires keyspace');
    const json = await fetchJson(conn, `/v2/schemas/keyspaces/${encodeURIComponent(keyspace)}/tables`);
    return rowsFromUnknown(json)
      .map((row) => scalarString(row['name']) ?? scalarString(row['table_name']))
      .filter((name): name is string => !!name);
  }
}
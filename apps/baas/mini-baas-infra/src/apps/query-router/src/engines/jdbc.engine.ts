import { BadRequestException, Injectable, NotImplementedException } from '@nestjs/common';
import type { AdapterOp, EngineCaps, IDatabaseAdapter, QueryOpts, QueryResult } from '@mini-baas/database';
import { fetchJson, parseRemoteConnection, queryResultFromRows, rowsFromUnknown, validateResourceName } from './remote-engine-utils';

@Injectable()
export class JdbcEngine implements IDatabaseAdapter {
  readonly engine = 'jdbc';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: false,
      txIntra: true,
      stream: false,
      semantic: { joins: 'native', patternSearch: 'native', ddl: false, migrationVersioning: false, latencyClass: 'adapter' },
    };
  }

  async execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult> {
    validateResourceName(resource, 'JDBC');
    if (op === 'upsert') {
      throw new NotImplementedException('Generic JDBC upsert is dialect-dependent; register a dialect-specific adapter instead.');
    }
    const conn = parseRemoteConnection(connectionString);
    const json = await fetchJson(conn, '/execute', {
      method: 'POST',
      body: { resource, op, opts, ownerId: opts.userId },
    });
    return queryResultFromRows(rowsFromUnknown(json));
  }

  async listResources(connectionString: string): Promise<string[]> {
    const conn = parseRemoteConnection(connectionString);
    const json = await fetchJson(conn, '/resources');
    const rows = rowsFromUnknown(json);
    if (rows.length === 0 && Array.isArray(json)) return json.map(String);
    const resources = rows.map((row) => row['name'] ?? row['resource']).filter((value) => value != null).map(String);
    if (!resources.length) throw new BadRequestException('JDBC sidecar did not return resources');
    return resources;
  }
}
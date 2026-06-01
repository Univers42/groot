import { BadRequestException, Injectable } from '@nestjs/common';
import type { AdapterOp, EngineCaps, IDatabaseAdapter, QueryOpts, QueryResult } from '@mini-baas/database';
import { fetchJson, getRequiredId, parseRemoteConnection, queryResultFromRows, rowsFromUnknown, validateResourceName, withOwner } from './remote-engine-utils';

@Injectable()
export class ElasticsearchEngine implements IDatabaseAdapter {
  readonly engine = 'elasticsearch';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: true,
      txIntra: false,
      stream: false,
      semantic: { joins: 'limited', patternSearch: 'native', ddl: false, migrationVersioning: false, latencyClass: 'adapter' },
    };
  }

  async execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult> {
    validateResourceName(resource, 'Elasticsearch');
    const conn = parseRemoteConnection(connectionString);
    const index = encodeURIComponent(resource);
    switch (op) {
      case 'list':
      case 'get': {
        const filters = Object.entries(opts.filter ?? {}).map(([field, value]) => ({ term: { [field]: value } }));
        if (opts.userId) filters.push({ term: { ownerId: opts.userId } });
        const json = await fetchJson(conn, `/${index}/_search`, {
          method: 'POST',
          body: { size: op === 'get' ? 1 : Math.min(opts.limit ?? 100, 500), from: opts.offset ?? 0, query: { bool: { filter: filters } } },
        });
        const hits = (json as { hits?: { hits?: Array<{ _id: string; _source?: Record<string, unknown> }> } }).hits?.hits ?? [];
        return queryResultFromRows(hits.map((hit) => ({ id: hit._id, ...(hit._source ?? {}) })));
      }
      case 'insert':
      case 'upsert': {
        const id = opts.data?.['id'];
        const path = id == null ? `/${index}/_doc` : `/${index}/_doc/${encodeURIComponent(String(id))}`;
        const json = await fetchJson(conn, path, { method: id == null ? 'POST' : 'PUT', body: withOwner(opts.data, opts) });
        return queryResultFromRows(rowsFromUnknown(json));
      }
      case 'update': {
        const id = getRequiredId(opts, op);
        const json = await fetchJson(conn, `/${index}/_update/${encodeURIComponent(id)}`, { method: 'POST', body: { doc: withOwner(opts.data, opts) } });
        return queryResultFromRows(rowsFromUnknown(json));
      }
      case 'delete': {
        const id = getRequiredId(opts, op);
        await fetchJson(conn, `/${index}/_doc/${encodeURIComponent(id)}`, { method: 'DELETE' });
        return { rows: [], rowCount: 1 };
      }
      default:
        throw new BadRequestException(`Unknown operation: ${op}`);
    }
  }

  async listResources(connectionString: string): Promise<string[]> {
    const conn = parseRemoteConnection(connectionString);
    const json = await fetchJson(conn, '/_cat/indices?format=json');
    return rowsFromUnknown(json).map((row) => String(row['index'] ?? '')).filter(Boolean);
  }
}
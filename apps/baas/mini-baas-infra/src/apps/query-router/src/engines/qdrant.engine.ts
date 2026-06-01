import { BadRequestException, Injectable } from '@nestjs/common';
import type { AdapterOp, EngineCaps, IDatabaseAdapter, QueryOpts, QueryResult } from '@mini-baas/database';
import { fetchJson, getRequiredId, parseRemoteConnection, queryResultFromRows, rowsFromUnknown, validateResourceName, withOwner } from './remote-engine-utils';

@Injectable()
export class QdrantEngine implements IDatabaseAdapter {
  readonly engine = 'qdrant';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: true,
      txIntra: false,
      stream: false,
      semantic: { joins: 'none', patternSearch: 'indexed', ddl: false, migrationVersioning: false, latencyClass: 'adapter' },
    };
  }

  async execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult> {
    validateResourceName(resource, 'Qdrant');
    const conn = parseRemoteConnection(connectionString);
    const collection = encodeURIComponent(resource);
    switch (op) {
      case 'list':
      case 'get': {
        const must = opts.userId ? [{ key: 'ownerId', match: { value: opts.userId } }] : [];
        const json = await fetchJson(conn, `/collections/${collection}/points/scroll`, {
          method: 'POST',
          body: { limit: op === 'get' ? 1 : Math.min(opts.limit ?? 100, 500), filter: { must }, with_payload: true, with_vector: false },
        });
        const points = (json as { result?: { points?: Array<{ id: string | number; payload?: Record<string, unknown> }> } }).result?.points ?? [];
        return queryResultFromRows(points.map((point) => (point.payload ? { id: point.id, ...point.payload } : { id: point.id })));
      }
      case 'insert':
      case 'update':
      case 'upsert': {
        const data = withOwner(opts.data, opts);
        const id = data['id'] ?? getRequiredId({ ...opts, data }, 'upsert');
        const vector = data['vector'];
        if (!Array.isArray(vector)) throw new BadRequestException('Qdrant write requires data.vector');
        const payload = { ...data };
        delete payload['vector'];
        delete payload['id'];
        const json = await fetchJson(conn, `/collections/${collection}/points`, {
          method: 'PUT',
          body: { points: [{ id, vector, payload }] },
        });
        return queryResultFromRows(rowsFromUnknown(json));
      }
      case 'delete': {
        const id = getRequiredId(opts, op);
        await fetchJson(conn, `/collections/${collection}/points/delete`, { method: 'POST', body: { points: [id] } });
        return { rows: [], rowCount: 1 };
      }
      default:
        throw new BadRequestException(`Unknown operation: ${op}`);
    }
  }

  async listResources(connectionString: string): Promise<string[]> {
    const conn = parseRemoteConnection(connectionString);
    const json = await fetchJson(conn, '/collections');
    const collections = (json as { result?: { collections?: Array<{ name: string }> } }).result?.collections ?? [];
    return collections.map((collection) => collection.name);
  }
}
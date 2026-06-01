import { BadRequestException, Injectable, NotImplementedException } from '@nestjs/common';
import type { AdapterOp, EngineCaps, IDatabaseAdapter, QueryOpts, QueryResult } from '@mini-baas/database';
import { fetchJson, parseRemoteConnection, queryResultFromRows, rowsFromUnknown, validateResourceName } from './remote-engine-utils';

@Injectable()
export class InfluxEngine implements IDatabaseAdapter {
  readonly engine = 'influx';

  capabilities(): EngineCaps {
    return {
      read: true,
      write: true,
      upsert: false,
      txIntra: false,
      stream: false,
      semantic: { joins: 'limited', patternSearch: 'none', ddl: false, migrationVersioning: false, latencyClass: 'adapter' },
    };
  }

  async execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult> {
    validateResourceName(resource, 'InfluxDB');
    const conn = parseRemoteConnection(connectionString);
    if (!conn.org || !conn.bucket) throw new BadRequestException('Influx connection_string requires org and bucket');
    switch (op) {
      case 'list':
      case 'get': {
        const ownerFilter = opts.userId ? `|> filter(fn: (r) => r.ownerId == "${opts.userId}")` : '';
        const flux = `from(bucket: "${conn.bucket}") |> range(start: -30d) |> filter(fn: (r) => r._measurement == "${resource}") ${ownerFilter} |> limit(n: ${op === 'get' ? 1 : Math.min(opts.limit ?? 100, 500)})`;
        const json = await fetchJson(conn, `/api/v2/query?org=${encodeURIComponent(conn.org)}`, {
          method: 'POST',
          headers: { Accept: 'application/csv' },
          body: { query: flux, type: 'flux' },
        });
        return typeof json === 'string' ? queryResultFromRows([{ csv: json }]) : queryResultFromRows(rowsFromUnknown(json));
      }
      case 'insert': {
        const line = this.toLineProtocol(resource, opts);
        await fetchJson(conn, `/api/v2/write?org=${encodeURIComponent(conn.org)}&bucket=${encodeURIComponent(conn.bucket)}&precision=ns`, {
          method: 'POST',
          headers: { 'Content-Type': 'text/plain' },
          body: line,
        });
        return { rows: [{ line }], rowCount: 1 };
      }
      case 'update':
      case 'delete':
      case 'upsert':
        throw new NotImplementedException(`InfluxDB does not support ${op} through the safe BaaS adapter`);
      default:
        throw new BadRequestException(`Unknown operation: ${op}`);
    }
  }

  async listResources(connectionString: string): Promise<string[]> {
    const conn = parseRemoteConnection(connectionString);
    if (!conn.org || !conn.bucket) throw new BadRequestException('Influx connection_string requires org and bucket');
    const flux = `import "influxdata/influxdb/schema" schema.measurements(bucket: "${conn.bucket}")`;
    const json = await fetchJson(conn, `/api/v2/query?org=${encodeURIComponent(conn.org)}`, { method: 'POST', body: { query: flux, type: 'flux' } });
    return rowsFromUnknown(json).map((row) => String(row['_value'] ?? row['name'] ?? '')).filter(Boolean);
  }

  private toLineProtocol(resource: string, opts: QueryOpts): string {
    const data = opts.data ?? {};
    const tags = [`ownerId=${this.escapeTag(opts.userId ?? 'anonymous')}`];
    const fields = Object.entries(data)
      .filter(([key]) => key !== 'id' && key !== 'time')
      .map(([key, value]) => `${this.escapeKey(key)}=${this.formatField(value)}`)
      .join(',');
    if (!fields) throw new BadRequestException('Influx insert requires at least one field');
    const time = typeof data['time'] === 'string' || typeof data['time'] === 'number' ? ` ${data['time']}` : '';
    return `${this.escapeKey(resource)},${tags.join(',')} ${fields}${time}`;
  }

  private escapeKey(value: string): string {
    return value.replace(/[ ,=]/g, '\\$&');
  }

  private escapeTag(value: string): string {
    return this.escapeKey(value);
  }

  private formatField(value: unknown): string {
    if (typeof value === 'number') return Number.isInteger(value) ? `${value}i` : String(value);
    if (typeof value === 'boolean') return String(value);
    return `"${String(value ?? '').replace(/"/g, '\\"')}"`;
  }
}
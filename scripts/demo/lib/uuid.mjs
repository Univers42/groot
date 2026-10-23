// UUIDv5 (RFC 9562 §5.5) over node:crypto sha1, so every demo row id is a pure function of its
// table and key: a re-run upserts the same ids instead of minting new rows.
import { createHash } from 'node:crypto';

export const NS_DNS = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

function uuidBytes(uuid) {
  return Buffer.from(uuid.replace(/-/g, ''), 'hex');
}

// Argument order is (name, namespace), as in the npm `uuid` package's v5().
export function uuidv5(name, namespace) {
  const hash = createHash('sha1').update(uuidBytes(namespace)).update(String(name), 'utf8').digest();
  hash[6] = (hash[6] & 0x0f) | 0x50;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  const hex = hash.subarray(0, 16).toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// Fixed forever: changing it would re-key every row of a seeded mount on the next run.
export const NS_ARLET = uuidv5('arlet-demo.prismatica.test', NS_DNS);

export function idFor(table, key) {
  return uuidv5(`${table}:${key}`, NS_ARLET);
}

const WORKSPACES = new Set(['operations', 'finance']);

// The two demo workspaces' ids, derived rather than stored so the orchestrator and the loader agree.
export function workspaceId(uid8, workspace) {
  if (!/^[0-9a-f]{8}$/.test(uid8)) throw new Error(`workspaceId: uid8 must be 8 lowercase hex digits (got ${uid8})`);
  if (!WORKSPACES.has(workspace)) throw new Error(`workspaceId: workspace must be operations or finance (got ${workspace})`);
  return uuidv5(`arlet:${uid8}:${workspace}`, NS_ARLET);
}

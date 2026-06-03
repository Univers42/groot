/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engines.test-d.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/01 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// **Compile-time** assertions for M10 capability-typed clients.
//
// This file is **expected to compile** under `tsc --noEmit`. If TypeScript
// complains, capability typing has drifted. The `// @ts-expect-error` lines
// are the inverse: they MUST trigger an error — if the line silently
// compiles, the type narrowing is broken and the SDK lies to its users.
//
// To verify locally:
//   cd apps/baas/sdk && npx tsc --noEmit -p tsconfig.json

import type { EngineClient, StreamableEngine, TransactionalEngine, UpsertableEngine } from '../index.js';

// ── 1) Always-present base operations ────────────────────────────────────────
declare const pg: EngineClient<'postgresql', { id: string; name: string }>;
declare const mongo: EngineClient<'mongodb', { _id: string; amount: number }>;
declare const redis: EngineClient<'redis', { id: string; value: string }>;
declare const http: EngineClient<'http', { id: string; payload: unknown }>;

// All five base ops exist on every engine — these must type-check.
void pg.list;
void pg.get;
void pg.insert;
void pg.update;
void pg.delete;
void mongo.list;
void redis.list;
void http.list;

// ── 2) Capability narrowing — POSITIVE cases (must compile) ──────────────────
// postgresql.caps.txIntra === true  → transaction() exists
void pg.transaction;
// postgresql.caps.upsert === false  → upsert is absent (positive: redis has it)
void redis.upsert;
// mongodb.caps.stream === true      → subscribe() exists
void mongo.subscribe;
// http.caps.upsert === true         → upsert() exists
void http.upsert;

// ── 3) Capability narrowing — NEGATIVE cases (must FAIL to compile) ─────────
// If any of these lines silently compile, the type narrowing is broken.

// @ts-expect-error postgresql.caps.upsert === false → no .upsert()
void pg.upsert;

// @ts-expect-error postgresql.caps.stream === false → no .subscribe()
void pg.subscribe;

// @ts-expect-error mongodb.caps.txIntra === false → no .transaction()
void mongo.transaction;

// @ts-expect-error redis.caps.txIntra === false → no .transaction()
void redis.transaction;

// @ts-expect-error redis.caps.stream === false → no .subscribe()
void redis.subscribe;

// @ts-expect-error http.caps.txIntra === false → no .transaction()
void http.transaction;

// @ts-expect-error http.caps.stream === false → no .subscribe()
void http.subscribe;

// ── 4) Discriminated-union helpers ──────────────────────────────────────────
// `StreamableEngine` should equal exactly the engines whose caps.stream===true.
// Post-audit: the 6 stub engines (jdbc/cassandra/neo4j/elasticsearch/qdrant/
// influx) were dropped from ENGINE_CAPS, so they no longer appear in these
// derived union types. Tests check the 5 real engines only.
const streamables: StreamableEngine[] = ['mongodb'];
void streamables;

// @ts-expect-error postgresql.caps.stream === false → not a StreamableEngine
const wrongStream: StreamableEngine = 'postgresql';
void wrongStream;

// `TransactionalEngine` should equal exactly engines with txIntra===true.
const tx: TransactionalEngine[] = ['postgresql', 'mysql'];
void tx;

// @ts-expect-error mongodb.caps.txIntra === false → not a TransactionalEngine
const wrongTx: TransactionalEngine = 'mongodb';
void wrongTx;

// `UpsertableEngine` excludes postgresql (caps.upsert === false).
const upsertable: UpsertableEngine[] = ['mysql', 'redis', 'http'];
void upsertable;

// @ts-expect-error postgresql.caps.upsert === false → not an UpsertableEngine
const wrongUpsert: UpsertableEngine = 'postgresql';
void wrongUpsert;

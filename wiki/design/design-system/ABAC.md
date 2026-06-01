# ABAC — Attribute-Based Access Control

> **Why ABAC and not RBAC?** Because the BaaS is multi-engine. PostgreSQL has
> RLS, MongoDB has roles per collection, Redis has ACLs, Elasticsearch has
> document-level security — **all incompatible**. Trying to enforce
> authorization at each engine's native layer means duplicating policy in
> five different DSLs, with five different bug surfaces. ABAC at the gateway
> is the only way to keep policy single-sourced when the storage tier is
> heterogeneous.
>
> See [`wiki/back/agent-prompt-agnostic-baas.md`](../../back/agent-prompt-agnostic-baas.md)
> for the engineering plan that builds this out (M9 — Centralized ABAC).

## The model

A policy decision answers:

> "Is **subject** S allowed to perform **action** A on **resource** R, given the
> **environment** E?"

Where:

- **Subject** (`S`) = `{ user_id, role, workspace_id, attributes }` — derived
  from the JWT validated by Kong.
- **Action** (`A`) = one of `list | get | insert | update | delete | upsert`
  — the `AdapterOp` from the IDatabaseAdapter contract.
- **Resource** (`R`) = `{ engine, resource_name, owner_id, tags, metadata }`
  — derived from `tenant_databases` + `schema_registry`.
- **Environment** (`E`) = `{ ip, time, request_id, idempotency_key }` —
  derived from the inbound request.

The decision is `{ allow: bool, reason: string, mask?: FieldMask }`. Field
masks let the gateway return a row with sensitive columns blanked
(`email_hash` instead of `email`) without two separate API endpoints.

## Where it lives in the stack

```
┌─────────────────────────────────────────────────────────────┐
│  Client (SDK)                                               │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTPS + JWT
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  WAF + Kong                                                 │
│    • signs/verifies JWT                                     │
│    • forwards X-User-Id / X-User-Email / X-User-Role        │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  AuthGuard (NestJS, in every mutating service)              │
│    • populates req.user from trusted Kong headers           │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  ABAC decision call (M9 plan)                               │
│    POST /permissions/decide                                 │
│    { user, resource_type, resource_name, op, attributes }   │
│       │                                                     │
│       ▼                                                     │
│    permission-engine                                        │
│    ─ delegates to public.has_permission() in PG             │
│    ─ deny-first, priority-DESC ordering                     │
│    ─ JSONB conditions (`{owner_only:true}`, etc.)           │
└──────────────────────────┬──────────────────────────────────┘
                           │ allow=true ─▶
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  IDatabaseAdapter.execute(connectionString, resource, op…)  │
│    • PG: SET LOCAL app.current_user_id, RLS kicks in        │
│    • Mongo: filter `owner_id`                               │
│    • Redis: namespace `userId:resource:id`                  │
│    • etc.                                                   │
└─────────────────────────────────────────────────────────────┘
```

The crucial point: **native engine ACLs are defense in depth, not the source
of truth**. Even if a Mongo `role` slips and grants too much, the gateway
ABAC denied the request before any DB driver was ever invoked.

## Today (what is already in place)

| Piece | Status | Reference |
|---|---|---|
| Roles in DB | ✅ | `roles` table seeded with `admin`, `user`, `guest`, `moderator`, `service_role` (migration 007) |
| Resource policies | ✅ | `resource_policies` table — JSONB conditions, priority, allow/deny |
| `public.has_permission()` evaluator | ✅ | Deny-first, priority-DESC; in migration 007 |
| RolesGuard at controller level | ✅ | `apps/baas/mini-baas-infra/src/libs/common/src/guards/roles.guard.ts` |
| ABAC engine on the frontend (cache-first, TTL 5 min) | ✅ | `apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/engine.ts` |
| Centralized `/permissions/decide` HTTP endpoint | ⚠️ M9 | not yet — every service calls `has_permission()` directly via its own DB connection |
| Every `IDatabaseAdapter.execute` consults ABAC before dispatching | ⚠️ M9 | not yet wired uniformly |
| Field-level mask in decision response | ⚠️ M9 | designed, not implemented |
| Pluggable rule engine (OPA / Cedar) | ⚠️ later | the in-PG evaluator is enough for M9; M5 spec mentions OPA as a future option |

## Why "attribute-based" beats "role-based" for this BaaS

A pure RBAC says: "If your role is `editor`, you can update any page in
your workspace." That breaks down for:

- **Per-resource overrides** — a user may be `editor` overall but `viewer`
  on a single sensitive page. ABAC handles this via `target: {type:'user',
  userId:X}` rules with `explicit: true`.
- **Owner-only operations** — a `user` can update a row only if
  `owner_id = auth.uid()`. RBAC has no native way to express "only on rows
  you own"; ABAC does it via the `{owner_only: true}` JSONB condition.
- **Time / IP / device attributes** — "admin actions allowed only from
  office IP between 9 and 18 UTC". RBAC can't express that without
  bolting on attributes anyway — so we just go ABAC from the start.

## Default-deny philosophy

Every adapter must enforce the following at the gateway layer (M9 plan):

```ts
const decision = await this.permissions.decide({
  userId,
  engine: this.engine,
  resource,
  op,
  attributes: { ip: req.ip, requestId: req.requestId },
});
if (!decision.allow) {
  throw new ForbiddenException(decision.reason);
}
return engine.execute(connectionString, resource, op, opts);
```

If `permission-engine` is unreachable, the adapter MUST fail closed
(throw `ServiceUnavailableException`) rather than fail open. That
fail-closed behaviour is non-negotiable — it's listed as invariant #1 in
the agent prompt.

## Concrete policy examples

### Example 1 — "Members CRUD their own; admins CRUD all"

Already seeded by migration 007:

```sql
INSERT INTO public.resource_policies
  (role_id, resource_type, resource_name, actions, conditions, effect, priority)
SELECT r.id, '*', '*',
       ARRAY['select','insert','update','delete'],
       '{"owner_only": true}'::jsonb,
       'allow', 0
FROM public.roles r WHERE r.name = 'user';

INSERT INTO public.resource_policies
  (role_id, resource_type, resource_name, actions, conditions, effect, priority)
SELECT r.id, '*', '*',
       ARRAY['select','insert','update','delete'],
       '{}'::jsonb,
       'allow', 100  -- higher priority overrides owner_only
FROM public.roles r WHERE r.name = 'admin';
```

### Example 2 — "Block deletes outside business hours for non-admins"

A new policy row (post-M9 capability — requires extending the conditions
evaluator):

```json
{
  "role": "user",
  "resource_type": "*",
  "actions": ["delete"],
  "conditions": { "time_range_utc": { "deny_between": [22, 6] } },
  "effect": "deny",
  "priority": 50
}
```

The evaluator interprets `time_range_utc.deny_between` and short-circuits
to `deny` outside business hours.

### Example 3 — "Field mask for PII on cross-workspace shares"

When a resource is shared with someone outside the owning workspace, the
decision returns a mask that hides PII columns:

```json
{
  "allow": true,
  "reason": "shared via workspace_invite",
  "mask": {
    "hide": ["email", "phone", "birthdate"],
    "redact": { "national_id": "xxx-xx-####" }
  }
}
```

The adapter then post-processes the rows to apply the mask before returning
them to Kong. The DB never sees the masking — it's purely policy-driven.

## The hard part — making ABAC fast

The naïve implementation calls `permission-engine` over HTTP on every
single query. That's a 5-20 ms latency tax per call, which kills the SDK's
responsiveness.

Counter-measures (M9.b — not in initial M9 scope):

1. **In-process cache** — every NestJS service caches decisions
   `(userId, engine, resource, op) → { allow, expires_at }` with a short
   TTL (5-30 s). This is exactly what the frontend's `AbacEngine.check()`
   already does.
2. **Invalidation on policy change** — when `resource_policies` is
   updated, `permission-engine` broadcasts an invalidation message on
   Redis Streams. Each service drops the matching cache entries.
3. **Precomputed effective permissions** — for hot paths (a user opening
   their workspace's main page), `permission-engine` can precompute the
   full effective ACL once at session start and cache it server-side. The
   client gets a token that encodes "user X can do {ops} on {resources}
   until {ts}".

Until M9.b lands, the safe default is "always call `permission-engine`,
accept the latency". Optimise once we have real load metrics.

## Implementation checklist for M9

- [ ] Create `permission-engine/src/decisions/decisions.controller.ts` with
      `POST /permissions/decide`.
- [ ] Delegate evaluation to `public.has_permission()` (already exists).
- [ ] Return `{ allow, reason }` (no mask for v1 — keep it simple).
- [ ] Add a `@ChecksPermissions(engine, op)` decorator that, when applied
      to a NestJS controller method, automatically calls
      `decisions.decide()` before the handler runs.
- [ ] Add the decorator to every mutating endpoint in `query-router`,
      `mongo-api`, `storage-router`, `gdpr-service`, `session-service`,
      `newsletter-service`.
- [ ] Verify script `scripts/verify/m9-abac.sh` (see agent prompt §2).
- [ ] Update `CHANGELOG.md` and add this file's status table.

## References

- [NIST SP 800-162 — Guide to Attribute-Based Access Control](https://csrc.nist.gov/publications/detail/sp/800-162/final)
  — the canonical reference, gives the formal model.
- [OWASP Access Control Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Access_Control_Cheat_Sheet.html)
  — fail-closed, default-deny, defense in depth.
- [Open Policy Agent](https://www.openpolicyagent.org/) — what we'd
  potentially swap `has_permission()` for if/when the policy language
  becomes too complex for PL/pgSQL.
- [Cedar (AWS)](https://www.cedarpolicy.com/) — AWS's open ABAC engine,
  another option for M9.b if we want a typed policy DSL.

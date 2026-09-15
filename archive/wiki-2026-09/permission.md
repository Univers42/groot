# Permissions in osionos — how the frontend and backend decide who can do what

> Real-code walkthrough of the osionos authorization model: the three layers that
> enforce it, **why it is ABAC (attribute-based) and not classic RBAC (role-based)**,
> the exact two snippets that show the difference, and how you write/seed a new rule.
> Every claim points at a `file:line` you can open.

---

## 0. TL;DR

osionos does **not** decide access from a role name alone ("you are an *editor*, so you may
edit"). It decides from **attributes of the request matched against attributes of the row**
("this row's `user_id` equals *your* `auth.uid()`", "your role carries `clearance >= 3`",
"the request IP is inside `10.0.0.0/8`"). That is **ABAC — Attribute-Based Access Control**.

Roles still exist, but they are **carriers of attributes**, not the access decision itself.
The decision is a predicate evaluated per request, per row.

Three layers enforce it, each independently (defence in depth):

| Layer | Where | Role | What it actually checks |
|---|---|---|---|
| **1. Frontend** (reflect) | osionos React/Vite app | *Hides* what you can't use | `AbacEngine.compute()` — cascading rules + role fallback |
| **2. Bridge** (gate) | `osionos-bridge` Node service | *Refuses* unscoped requests | HMAC signature + app-session token scoped to `workspace_ids` |
| **3. Database** (enforce) | Postgres RLS + control-plane PDP | *Cannot be bypassed* | RLS `USING (…)` predicates + `has_permission()` conditions |

**The frontend is not the security boundary — the database is.** The UI reflects the decision;
Postgres RLS and the control-plane Policy Decision Point *make* it. A hostile client that skips
the UI still hits RLS.

---

## 1. The mental model: RBAC vs ABAC in one paragraph

- **RBAC (Role-Based Access Control)** — "classic". You attach a **role** to a user
  (`admin`, `editor`, `viewer`), and grant the role a fixed set of actions on a resource type.
  The decision is `role ∈ allowed_roles`. Coarse, static, table-level.
- **ABAC (Attribute-Based Access Control)** — the decision is a **boolean predicate over
  attributes**: of the *subject* (their id, their role's `department`/`clearance`), of the
  *resource* (its `owner_id`, `tenant_id`, `is_private`), and of the *environment* (time, IP,
  auth-assurance-level). Fine-grained, dynamic, **row-level and field-level**.

osionos is **ABAC built on top of a thin RBAC base**. The RBAC base answers "may this role
*reach* the table at all" (a coarse `GRANT`); ABAC answers "**which rows**, and **which
fields**, for **this specific caller right now**". RBAC is the bouncer at the door; ABAC is the
rule that decides which seats you may take once inside.

---

## 2. The headline comparison — the *same* rule, written two ways

The single most important thing to see: the codebase contains **both** styles literally
side by side in the same migration file. This is the comparison you asked for.

### 2a. The classic RBAC way (coarse, role-only)

From [models/osionos-chat-migration.sql:156-161](models/osionos-chat-migration.sql#L156-L161)
and the service-role bypass at
[:132-134](models/osionos-chat-migration.sql#L132-L134):

```sql
-- RBAC: the role 'authenticated' may SELECT this table. Full stop.
GRANT SELECT ON public.osionos_channels         TO authenticated;
GRANT SELECT ON public.osionos_channel_members  TO authenticated;
GRANT SELECT ON public.osionos_messages         TO authenticated;

-- RBAC: the role 'service_role' may do anything, unconditionally.
CREATE POLICY osionos_channels_service_role_all ON public.osionos_channels
  FOR ALL TO service_role USING (true) WITH CHECK (true);   -- USING (true) = no filter
```

**What this decides:** *"Are you in the `authenticated` role?"* If yes → you may read the
table. **Every row of it.** The decision is the role name and nothing else. `USING (true)`
literally means "no row filter". This is textbook RBAC.

### 2b. The ABAC way (fine-grained, attribute predicate) — what osionos actually relies on

From the *same file*,
[models/osionos-chat-migration.sql:101-103](models/osionos-chat-migration.sql#L101-L103) (ownership)
and [:85-99](models/osionos-chat-migration.sql#L85-L99) (membership):

```sql
-- ABAC: you see a membership row ONLY if it is YOUR row.
CREATE POLICY osionos_channel_members_select_own ON public.osionos_channel_members
  FOR SELECT TO authenticated USING (user_id = auth.uid());   -- ← row attr vs request attr

-- ABAC: you see a channel ONLY if you are a member of it,
--       OR (for public channels) a member of its workspace.
CREATE POLICY osionos_channels_select_member ON public.osionos_channels
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.osionos_channel_members cm
            WHERE cm.channel_id = id AND cm.user_id = auth.uid())
    OR (NOT is_private AND kind <> 'dm'
        AND EXISTS (SELECT 1 FROM public.osionos_workspace_members wm
                    WHERE wm.workspace_id = public.osionos_channels.workspace_id
                      AND wm.user_id = auth.uid()))
  );
```

**What this decides:** *"Does this **row's** `user_id` / membership match **your** `auth.uid()`,
given this row's `is_private` and `kind` **attributes**?"* The role `authenticated` is the same
for everyone — it is **not** the decision. The decision is the attribute predicate, evaluated
**per row** against **your** identity.

### 2c. Read the two side by side

| | **RBAC snippet (2a)** | **ABAC snippet (2b)** |
|---|---|---|
| Decision input | role name (`authenticated`) | row attributes (`user_id`, `is_private`) vs request attribute (`auth.uid()`) |
| Granularity | whole table | individual row |
| Two users, same role | see **identical** data | see **different** data |
| Add a private channel | needs new role/table | **zero** policy change — predicate already covers it |
| `USING` clause | `USING (true)` | `USING (user_id = auth.uid())` |

The GRANT in 2a is real and necessary — it is the coarse "may you reach the table" gate. But
**if osionos had stopped at 2a (pure RBAC), every authenticated user would read every channel
in the database.** The 2b policies are what make the data actually private. That is the whole
argument for ABAC in one screen.

---

## 3. How `auth.uid()` gets its value — the request attribute pipeline

The ABAC predicate `user_id = auth.uid()` is only meaningful if `auth.uid()` reliably resolves
to *this* caller. That is the job of the upper two layers.

```
Browser ──(opposite-osiris login)──▶ osionos-bridge ──(JWT w/ sub=user id)──▶ Postgres
                                          │                                       │
                                  signs app-session                       request.jwt.claim.sub
                                  token scoped to                         ⇒ auth.uid()
                                  workspace_ids + roles                   ⇒ RLS predicates fire
```

1. **Bridge verifies the handoff** — the site signs a request with `OSIONOS_BRIDGE_SHARED_SECRET`;
   the bridge checks an HMAC-SHA256 signature + a ±5-min timestamp window + a replay nonce before
   it trusts the identity:
   [apps/osionos/app/scripts/bridge-api.mjs:351-370](apps/osionos/app/scripts/bridge-api.mjs#L351-L370).
2. **Bridge mints a scoped app-session token** carrying the user's `sub`, the list of
   `workspace_ids` they belong to, and a per-workspace `roles` map — the *attributes* later
   layers key on:
   [bridge-api.mjs:372-392](apps/osionos/app/scripts/bridge-api.mjs#L372-L392).
3. **Bridge enforces the scope on every call** — `requireWorkspaceAccess()` rejects (403) any
   request whose target workspace is not in the token's `workspace_ids`, then re-checks the
   member's `permissions` array:
   [bridge-api.mjs:761-792](apps/osionos/app/scripts/bridge-api.mjs#L761-L792).
4. **Postgres turns the JWT `sub` into `auth.uid()`**, and the RLS predicates from §2b fire.

So the email is never even stored raw — only an HMAC hash of it, salted with
`OSIONOS_BRIDGE_EMAIL_HASH_SALT`, maps `(provider, subject) → workspace`
([bridge-api.mjs:163-230](apps/osionos/app/scripts/bridge-api.mjs#L163-L230)).

---

## 4. Layer 1 — the frontend: ABAC that *reflects*, never *enforces*

The frontend's only job is to grey-out / hide what you can't do, so the UI feels right —
**the server still re-checks everything.** There are two pieces here, and it's worth keeping them
straight:

- **The literal browser gate** — pure functions in `pageAccess.ts` that the sidebar/menus call to
  decide whether to *render* a Read/Edit/Delete affordance.
- **The object-database's ABAC engine** — `AbacEngine` inside the embedded `notion-database-sys`
  package, a Mongoose-backed resolver used by the live-database pages. It's app code, not the
  database RLS of §5 — so it is still a *reflect* layer, just a richer one.

### 4a₀. The browser gate — attribute checks in plain TypeScript

[apps/osionos/app/src/shared/lib/auth/pageAccess.ts:134-165](apps/osionos/app/src/shared/lib/auth/pageAccess.ts#L134-L165):

```ts
export function canReadPage(page: PageEntry, context: PageAccessContext | null): boolean {
  if (!context || !hasWorkspaceAccess(page, context)) return false;
  const visibility = normalizePageVisibility(page.visibility);
  if (visibility === "public") return true;                       // resource attr: visibility
  if (visibility === "shared") return true;
  if (page.ownerId && page.ownerId === context.userId) return true;  // ownership attr
  if (isLegacyPage(page)) return true;
  return getCollaboratorRole(page, context.userId) !== null;      // collaborator attr
}

export function canEditPage(page: PageEntry, context: PageAccessContext | null): boolean {
  if (!context || !hasWorkspaceAccess(page, context)) return false;
  if (context.sharedWorkspaceIds.includes(page.workspaceId)) return true;
  if (page.ownerId && page.ownerId === context.userId) return true;
  if (isLegacyPage(page)) return true;
  const collaboratorRole = getCollaboratorRole(page, context.userId);
  return collaboratorRole === "editor" || collaboratorRole === "owner";
}
```

Even here, at the cheapest layer, the decision is **attributes** (`visibility`, `ownerId ===
userId`, collaborator role) — never a bare role name. `canDeletePage` is literally
`return canEditPage(...)` ([:167-172](apps/osionos/app/src/shared/lib/auth/pageAccess.ts#L167-L172)).
But this runs in the browser against a client cache, so it is **UX only**: the authority is §5/§6.

### 4a. The access-rule shape — ABAC targets, not just roles

[apps/osionos/app/src/shared/notion-database-sys/packages/core/src/models/accessRule.model.ts:18-39](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/models/accessRule.model.ts#L18-L39):

```ts
const targetSchema = new Schema({
  type: { type: String, enum: ['user', 'role', 'workspace', 'public'], required: true },
  userId: { type: Schema.Types.ObjectId, ref: 'User' },
  role: String,
}, { _id: false });

const accessRuleSchema = new Schema({
  workspaceId: { type: Schema.Types.ObjectId, required: true, ref: 'Workspace', index: true },
  resourceId:  { type: Schema.Types.ObjectId },                       // null = workspace default
  resourceType:{ type: String, enum: ['workspace','page','database','block'], required: true },
  target:      { type: targetSchema, required: true },               // ← who: user | role | workspace | public
  permission:  { type: String, enum: ['no_access','can_view','can_comment','can_edit','full_access'], required: true },
  explicit:    { type: Boolean, default: false },                    // ← explicit overrides inherited
}, { timestamps: true });
```

A rule can target a **user**, a **role**, the **whole workspace**, or the **public** — that
breadth of target is exactly what RBAC can't express (RBAC only ever targets a role).

### 4b. The decision — cascade first, fall back to role only when no rule exists

[apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/engine.ts:86-135](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/engine.ts#L86-L135):

```ts
private async compute(userId, workspaceId, resourceId, _resourceType): Promise<PermissionLevel> {
  const member = await WorkspaceMemberModel.findOne({ workspaceId, userId }).lean();
  if (!member) return 'no_access';
  if (member.role === 'owner') return 'full_access';            // owner shortcut

  // Gather rules that apply to THIS user, by attribute target (user | role | public | workspace)
  const rules = await AccessRuleModel.find({
    workspaceId,
    $and: [
      { $or: [ { resourceId: null, resourceType: 'workspace' }, { resourceId } ] },
      { $or: [
        { 'target.type': 'workspace' },
        { 'target.type': 'role', 'target.role': member.role },     // ← attribute: role
        { 'target.type': 'user', 'target.userId': userId },        // ← attribute: identity
        { 'target.type': 'public' },
      ] },
    ],
  }).sort({ resourceType: 1 }).lean();                            // workspace < page < database < block

  if (rules.length === 0) {
    // ── This branch is the *pure RBAC* fallback — used only when nobody set an ABAC rule ──
    switch (member.role) {
      case 'admin':  return 'full_access';
      case 'member': return 'can_edit';
      case 'guest':  return 'can_view';
      default:       return 'no_access';
    }
  }
  return resolvePermission(rules.map(r => ({ permission: r.permission, explicit: r.explicit })));
}
```

This single function is the best in-repo illustration of the two models coexisting:

- **Lines 122-130 are classic RBAC** — no attribute rules exist, so the answer is purely
  `switch (member.role)`. Coarse and fine for a brand-new workspace.
- **Everything above is ABAC** — the moment a single `AccessRule` exists, the decision becomes a
  *cascade* (workspace default → page → block, most-specific-wins) over attribute targets, with
  `explicit` rules overriding inherited ones
  ([resolver.ts:44-61](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/resolver.ts#L44-L61)).

The `check()` wrapper compares the resolved level against a required level on a 5-step ladder
(`no_access < can_view < can_comment < can_edit < full_access`):
[engine.ts:30-40](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/engine.ts#L30-L40).

> **Why this is "reflect, not enforce":** this runs in the browser against a client cache. It
> exists for UX (don't show an Edit button you can't use). The authority is §5 and §6.

---

## 5. Layer 3a — the database RLS: ABAC that *cannot* be bypassed

Postgres Row-Level Security is where the attribute predicate becomes non-negotiable: it is
applied by the database engine on every query, no matter what client sent it.

The bridge's own page tables show ABAC that even reads a **per-member permissions array** (not
just a role) — [models/osionos-bridge-migration.sql:175-184](models/osionos-bridge-migration.sql#L175-L184):

```sql
CREATE POLICY osionos_pages_select_member ON public.osionos_pages
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.osionos_workspace_members member
      WHERE member.workspace_id = public.osionos_pages.workspace_id
        AND member.user_id = auth.uid()
        AND member.permissions && ARRAY['read', 'admin']::TEXT[]   -- ← attribute: permission set overlap
    )
  );
```

`member.permissions && ARRAY['read','admin']` is an array-overlap test — *"does this member's
permission set intersect {read, admin}?"*. RBAC cannot say that; it only knows the role label.
The matching `workspaces_select_member` policy at
[:161-169](models/osionos-bridge-migration.sql#L161-L169) keys on `owner_id = auth.uid()`
OR membership — the ownership attribute again.

Multi-tenant isolation is the same idea at the tenant attribute level —
[apps/grobase/scripts/migrations/postgresql/040_tenant_usage.sql:57-59](apps/grobase/scripts/migrations/postgresql/040_tenant_usage.sql#L57-L59):

```sql
CREATE POLICY tenant_usage_tenant_isolation ON public.tenant_usage
  FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
  WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);   -- read AND write scoped to your tenant
```

`WITH CHECK` is the write half: it stops a caller from *writing* a row stamped with another
tenant's id. ABAC guards both directions.

---

## 6. Layer 3b — the control-plane PDP: attribute *conditions* + field masks

RLS answers "which rows". The grobase control plane adds a **Policy Decision Point (PDP)** that
answers "which **actions**, under which **environmental conditions**, and with which **fields
masked**". This is the richest ABAC in the stack and lives in migration `063`.

### 6a. The decision loop — priority, deny-first, condition-gated

[apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql:219-271](apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql#L219-L271):

```sql
CREATE OR REPLACE FUNCTION public.has_permission(
  p_user_id UUID, p_resource_type TEXT, p_resource_name TEXT, p_action TEXT,
  p_attrs JSONB DEFAULT '{}'::jsonb,            -- ← request attributes (ip, aal, owner, resource_id)
  p_conditions_enabled BOOLEAN DEFAULT false,   -- ← the ABAC flag (see 6c)
  p_resource_id TEXT DEFAULT NULL
) RETURNS BOOLEAN AS $fn$
DECLARE pol RECORD; found BOOLEAN := false; v_attrs JSONB;
BEGIN
  v_attrs := COALESCE(p_attrs, '{}'::jsonb);
  ...
  FOR pol IN
    SELECT rp.effect, rp.conditions
    FROM public.resource_policies rp
    JOIN public.user_roles ur ON ur.role_id = rp.role_id           -- ← role carries the policy
    WHERE ur.user_id = p_user_id
      AND (rp.resource_type = p_resource_type OR rp.resource_type = '*')
      AND (rp.resource_name = p_resource_name OR rp.resource_name = '*')
      AND p_action = ANY(rp.actions)
    ORDER BY rp.priority DESC, rp.effect ASC                        -- deny-first at same priority
  LOOP
    IF p_conditions_enabled                                         -- ← ABAC ON:
       AND pol.conditions IS NOT NULL AND pol.conditions <> '{}'::jsonb
       AND NOT auth.eval_conditions(pol.conditions, v_attrs) THEN   --   skip policy if attrs don't satisfy it
      CONTINUE;
    END IF;
    IF pol.effect = 'deny' THEN RETURN false; END IF;              -- deny wins
    found := true;
  END LOOP;
  RETURN found;
END;
$fn$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

### 6b. The condition evaluator — the attribute matcher

[063_permission_conditions.sql:99-195](apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql#L99-L195) —
`auth.eval_conditions(conditions, attrs)` checks the well-known keys:

- `time_window {after, before}` vs `now()`
- `ip_cidr [ … ]` vs the request IP (`inet <<=` containment)
- `aal` (auth-assurance level) vs the session's level
- `owner` vs `attrs.user_id` (ownership), and `resource_id` exact/`in` match

**Strict-on-known, ignore-unknown:** a *present* key that fails ⇒ `false`; an *unrecognised*
key is left to RLS. So the PDP and RLS compose instead of fighting.

### 6c. It is flag-gated OFF by default

`has_permission`'s `p_conditions_enabled` defaults `false`, so with the feature flags off the
function is **byte-identical to plain role evaluation** (RBAC). ABAC conditions only switch on
under `PERMISSION_CONDITIONS_ENABLED` / `API_KEY_ABAC_ENABLED` (gates m135–m139, migration
`063`) — see `apps/grobase/CLAUDE.md` → "fine-grained ABAC". This is the cleanest possible proof
that **RBAC is the floor and ABAC is the opt-in extension**: the same function is both,
depending on one boolean.

---

## 7. The real case — the Agency simulation (`make agency-all`)

The agency demo is osionos's worked example of *why* ABAC. It is a 20-person investigative
agency with 10 case-file tables (`cases`, `subjects`, `evidence`, `transactions`,
`communications`, …) where access must depend on **department** and **clearance** — something
RBAC fundamentally can't model without exploding into dozens of roles.

### 7a. Roles are attribute carriers

[apps/grobase/scripts/seed/agency-policies.sh:45-58](apps/grobase/scripts/seed/agency-policies.sh#L45-L58):

```sql
INSERT INTO public.roles (name, description, is_system, metadata) VALUES
  ('agency:director',     'Agency director — full authority', false, '{"department":"command","clearance":5,"org":"agency"}'),
  ('agency:case_manager', 'Case manager — runs case ops',     false, '{"department":"operations","clearance":4,"org":"agency"}'),
  ('agency:field_agent',  'Field agent — collection, low clearance', false, '{"department":"investigations","clearance":2,"org":"agency"}'),
  ('agency:analyst',      'Intelligence analyst — reads all, masked finance', false, '{"department":"analysis","clearance":3,"org":"agency"}'),
  ...
```

The role name is just a handle; the **`metadata` JSONB** (`department`, `clearance`) is what
policies actually read. Users are then mapped to roles from the roster at
[:61-74](apps/grobase/scripts/seed/agency-policies.sh#L61-L74).

### 7b. Policies are attribute + field-level, not "role X may do Y"

[apps/grobase/scripts/seed/agency-policies.sh:93-120](apps/grobase/scripts/seed/agency-policies.sh#L93-L120):

```sql
-- command: full authority on every table
SELECT pg_temp.pol('agency:director', '*', ARRAY['select','insert','update','delete'], 'allow', 100);

-- field agents (clearance 2): can read cases, BUT budget is redacted and SSN hidden;
--                             NO access to finance/comms at all.
SELECT pg_temp.pol('agency:field_agent', 'cases',    ARRAY['select'], 'allow', 70,
  '{"mask":{"redact":{"budget":"***"}}}');                       -- ← field-level ABAC
SELECT pg_temp.pol('agency:field_agent', 'subjects', ARRAY['select'], 'allow', 70,
  '{"mask":{"hide":["ssn"]}}');                                  -- ← field-level ABAC
SELECT pg_temp.pol('agency:field_agent', 'transactions',
  ARRAY['select','insert','update','delete'], 'deny', 90);       -- ← explicit deny, high priority
```

A field agent and an analyst are **both "authenticated"** to the database (same Postgres role),
yet the field agent sees `cases.budget` as `***`, no `subjects.ssn`, and zero `transactions`,
while the analyst sees redacted `transactions.amount`. **That per-field, per-clearance outcome
is impossible in classic RBAC** — there is no "role" whose grant says "SELECT but blank out one
column". You would need a separate masked view per (role × table) combination and a role for
every clearance/department crossing.

### 7c. The UI to author these conditions

Operators edit the well-known attribute keys (`clearance`, `department`, `time_window`) of a
policy's JSONB through a real settings panel —
[apps/osionos/app/src/features/settings/permissions/ConditionEditor.tsx:19-73](apps/osionos/app/src/features/settings/permissions/ConditionEditor.tsx#L19-L73)
— which writes straight into the `conditions` JSONB that §6b evaluates.

---

## 8. "What if we'd chosen the classic RBAC way instead?" — concrete consequences

Suppose osionos had stopped at the RBAC base (§2a) — `GRANT … TO authenticated`, plus the
frontend `switch(member.role)` fallback, and *no* RLS attribute predicates, *no* PDP conditions.
Using the same features as evidence, here is what would break:

| Scenario (real feature) | With **classic RBAC only** | With **ABAC** (what we built) |
|---|---|---|
| Two users in a shared workspace | Both `authenticated` → both read **all** channels/pages in the DB ([:156](models/osionos-chat-migration.sql#L156)) | Each reads only their channels/pages ([:101-103](models/osionos-chat-migration.sql#L101-L103)) |
| Private channel / DM | No way to express "only members" without a new role per channel | One predicate handles every channel forever ([:85-99](models/osionos-chat-migration.sql#L85-L99)) |
| Multi-tenant isolation | A tenant could read another tenant's `tenant_usage` | `tenant_id = auth.current_tenant_id()` blocks it ([040:57-59](apps/grobase/scripts/migrations/postgresql/040_tenant_usage.sql#L57-L59)) |
| Field agent + `cases.budget` | Whole-row or nothing — can't hide one column → leak the budget, or deny the whole case | `{"mask":{"redact":{"budget":"***"}}}` ([agency:109-110](apps/grobase/scripts/seed/agency-policies.sh#L109-L110)) |
| "Only from office IP, business hours" | Not expressible — roles have no IP/time axis | `ip_cidr` + `time_window` conditions ([063:99-195](apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql#L99-L195)) |
| Agency 10 tables × 9 departments × 4 clearances | **Role explosion** — dozens of bespoke roles + masked views | **One attribute matrix**, ~50 policies seeded from data ([agency-policies.sh](apps/grobase/scripts/seed/agency-policies.sh)) |
| New page shared with one external user | Add them to a role that grants the whole resource type | A single `target:{type:'user'}` AccessRule ([accessRule.model.ts:18-39](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/models/accessRule.model.ts#L18-L39)) |

**The summary of the trade-off:**

- **RBAC's advantage:** dead simple, easy to audit ("who is admin?"), cheap to evaluate. Perfect
  as the coarse base — which is exactly the role osionos keeps it in (the `GRANT`, the
  empty-workspace fallback, flag-off byte-parity).
- **ABAC's advantage:** expresses ownership, tenancy, per-field masking, time/IP/assurance — none
  of which RBAC can say — **without a combinatorial explosion of roles**, and it scopes **per row**
  so two users of the same role see different data. The cost is that a predicate is harder to read
  at a glance than a role list, and it must be evaluated against live request attributes.

osionos chose **ABAC enforced at the database, with RBAC as the coarse base and a flag to fall
back to pure RBAC** — so it gets RBAC's simplicity where that suffices and ABAC's precision where
it's required, and the security boundary (RLS) can never be skipped by a client.

---

## 9. How you write / set a new rule (cookbook)

### 9a. A coarse RBAC grant (reach-the-table)

```sql
-- "any logged-in user may read this table" — the floor, not the real protection
GRANT SELECT ON public.my_table TO authenticated;
ALTER TABLE public.my_table ENABLE ROW LEVEL SECURITY;   -- then ALWAYS add an ABAC policy ↓
```

### 9b. An ownership ABAC policy (the common case)

```sql
-- "you only ever see/modify your own rows"
CREATE POLICY my_table_own ON public.my_table
  FOR ALL TO authenticated
  USING      (user_id = auth.uid())     -- read filter
  WITH CHECK (user_id = auth.uid());    -- write filter (can't stamp someone else's id)
```

Pattern source: [models/osionos-chat-migration.sql:101-103](models/osionos-chat-migration.sql#L101-L103).

### 9c. A conditional (environmental) ABAC policy via the PDP

Insert a `resource_policies` row whose `conditions` JSONB carries the attribute constraints, then
run with `PERMISSION_CONDITIONS_ENABLED=1`:

```sql
SELECT pg_temp.pol('agency:analyst', 'audit_events', ARRAY['select'], 'allow', 10,
  '{"ip_cidr":["10.0.0.0/8","127.0.0.0/8"], "time_window":{"after":"2020-01-01T00:00:00Z"}}');
```

Evaluated by `auth.eval_conditions` →
[063_permission_conditions.sql:99-195](apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql#L99-L195).
Keys today: `time_window`, `ip_cidr`, `aal`, `owner`, `resource_id`, plus `mask:{hide|redact}` for
field-level masking.

### 9d. A frontend AccessRule (for the UI cascade)

Insert an `AccessRule` document (§4a schema) targeting a `user` / `role` / `workspace` / `public`,
with a `permission` level and `explicit` flag. `AbacEngine.compute()` will pick it up on the next
`check()`. Remember: this only changes what the UI *shows* — the DB policy in 9b/9c is the actual
guard.

---

## 10. Citations index (all verified `file:line`)

**Frontend (osionos React/Vite editor)**
- ABAC engine — cascade + RBAC fallback: [engine.ts:86-135](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/engine.ts#L86-L135)
- Permission ladder check: [engine.ts:30-40](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/engine.ts#L30-L40)
- AccessRule schema (targets + levels): [accessRule.model.ts:18-39](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/models/accessRule.model.ts#L18-L39)
- Cascade resolver (explicit-wins): [resolver.ts:44-61](apps/osionos/app/src/shared/notion-database-sys/packages/core/src/abac/resolver.ts#L44-L61)
- Condition editor UI: [ConditionEditor.tsx:19-73](apps/osionos/app/src/features/settings/permissions/ConditionEditor.tsx#L19-L73)

**Bridge (osionos-bridge handoff)**
- HMAC verify + skew + replay: [bridge-api.mjs:351-370](apps/osionos/app/scripts/bridge-api.mjs#L351-L370)
- Mint scoped app-session token: [bridge-api.mjs:372-392](apps/osionos/app/scripts/bridge-api.mjs#L372-L392)
- Verify token / scope: [bridge-api.mjs:394-438](apps/osionos/app/scripts/bridge-api.mjs#L394-L438)
- Workspace access gate (403): [bridge-api.mjs:761-792](apps/osionos/app/scripts/bridge-api.mjs#L761-L792)
- Email-hash identity: [bridge-api.mjs:163-230](apps/osionos/app/scripts/bridge-api.mjs#L163-L230)

**Database — RLS (DB-enforced ABAC)**
- Ownership policy: [osionos-chat-migration.sql:101-103](models/osionos-chat-migration.sql#L101-L103)
- Membership policy: [osionos-chat-migration.sql:85-99](models/osionos-chat-migration.sql#L85-L99)
- RBAC grant (coarse): [osionos-chat-migration.sql:156-161](models/osionos-chat-migration.sql#L156-L161)
- service_role bypass: [osionos-chat-migration.sql:132-134](models/osionos-chat-migration.sql#L132-L134)
- Page policy w/ permissions-array: [osionos-bridge-migration.sql:175-184](models/osionos-bridge-migration.sql#L175-L184)
- Tenant isolation: [040_tenant_usage.sql:57-59](apps/grobase/scripts/migrations/postgresql/040_tenant_usage.sql#L57-L59)

**Control plane — PDP (attribute conditions + masks)**
- `has_permission()` loop: [063_permission_conditions.sql:219-271](apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql#L219-L271)
- `auth.eval_conditions()`: [063_permission_conditions.sql:99-195](apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql#L99-L195)
- Agency roles + attributes: [agency-policies.sh:45-58](apps/grobase/scripts/seed/agency-policies.sh#L45-L58)
- Agency policy matrix + masks: [agency-policies.sh:93-120](apps/grobase/scripts/seed/agency-policies.sh#L93-L120)

**Flags / further reading**
- ABAC flags `PERMISSION_CONDITIONS_ENABLED` / `API_KEY_ABAC_ENABLED` (m135–m139, migration `063`):
  `apps/grobase/CLAUDE.md` → "fine-grained ABAC".
- JWT claims that feed `auth.uid()`: [wiki/architecture/JWT.md](wiki/architecture/JWT.md).
- Bridge design: [wiki/architecture/osionos-bridge-strategy.md](wiki/architecture/osionos-bridge-strategy.md).

---

### One-line takeaway

> **RBAC is the bouncer that checks your role at the door; ABAC is the rule that decides which
> seats you may take once inside.** osionos keeps the bouncer (coarse `GRANT`s, a flag-off
> fallback) but lets ABAC predicates — `user_id = auth.uid()`, `tenant_id = …`, `clearance >= n`,
> `ip_cidr ∈ …`, `mask:{hide|redact}` — make the real decision, **per row and per field, in the
> database where no client can skip it.**

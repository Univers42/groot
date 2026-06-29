# Permission engine — the ABAC/RBAC policy decision point (PDP)

> **In one sentence.** The permission engine is the policy decision point ([PDP](glossary.md#pdp-policy-decision-point)) that authorizes or denies every operation before it reaches the data plane, evaluating either role membership alone ([RBAC](glossary.md#rbac-role-based-access-control), fast) or roles plus request-level conditions like time windows and IP ranges ([ABAC](glossary.md#abac-attribute-based-access-control), fine-grained).

## What it is & why it exists

The permission engine is a dedicated NestJS service that acts as the authorization gatekeeper for Grobase. It evaluates **policies** — rules that map roles to resource operations — against the current user and request attributes, returning a decision (allow/deny) plus optional field masks for response redaction. It supports two modes: RBAC (role-based, stateless, fast) checks role membership only; ABAC (attribute-based) additionally gates policies by request-level conditions like time windows, IP CIDR ranges, authentication assurance level, owner identity, and per-instance resource IDs.

Policies are stored as priority-ordered rules in Postgres: a [role](glossary.md#role) grants actions on a resource type and name, with an [effect](glossary.md#effect) (allow or deny) and optional JSONB conditions. [Deny wins](glossary.md#deny-first) immediately at equal priority. The engine is also dual: the **NestJS PDP** evaluates conditions on request attributes (time, IP, AAL, owner, resource_id) before dispatch; the **Rust data-plane evaluator** deserializes a [policy bundle](glossary.md#policy-bundle) (user roles + policies) and evaluates allow/deny locally per request. Conditions and field masks are feature-flagged (PERMISSION_CONDITIONS_ENABLED) so the system remains [byte-parity](glossary.md#byte-parity) with the pre-conditions baseline when the flag is off.

## How it works

- Query-router receives a request with user identity (JWT or API key), operation (list/get/insert/update/delete/upsert), and resource (engine + table name).
- Query-router extracts or computes request attributes: caller IP, authentication assurance level, per-instance resource ID, and other context.
- Query-router calls permission-engine POST /permissions/decide with user ID, resource type/name, operation, and attributes.
- Permission-engine normalizes attributes (user_id, tenant_id, aal, ip, resource_id all present) and calls SQL has_permission(user, type, name, op, attrs_jsonb, conditions_enabled, resource_id).
- has_permission joins user_roles to resource_policies, orders by [priority](glossary.md#priority) DESC (deny-first at ties), and for each matching policy: if conditions are enabled and non-empty, calls auth.eval_conditions(policy.conditions, attrs); if the condition fails, skips that policy (conditional allow); if it passes and the effect is deny, returns false; if it passes and the effect is allow, marks found=true.
- Permission-engine returns PermissionDecision: {allow: boolean, reason: string, mode: 'rbac'|'abac', mask?: FieldMask}. In ABAC mode, it optionally resolves [field masks](glossary.md#field-mask) (hide/redact directives) from matching policies.
- Query-router receives the decision. If denied (allow=false), it returns 403 Forbidden. If allowed, it applies the field mask (if present) to responses and forwards the query to the data plane.
- The Rust data-plane, if operating in a local ABAC mode, deserializes a fresh policy bundle (from BundlesService.latest()) and performs a parallel allow/deny check for defense-in-depth, then executes the query [owner-scoped](glossary.md#owner-scoping) by RLS.

## The code that does it

**What to look at:** The core decide() method dispatches to SQL has_permission(), optionally resolves field masks in ABAC mode, and returns allow/deny with metadata.

```ts
// apps/grobase/src/apps/permission-engine/src/decisions/decisions.service.ts:70-109
  async decide(dto: DecidePermissionDto): Promise<PermissionDecision> {
    const action = this.actionForOp(dto.op);
    const attrs = this.buildAttrs(dto);
    const resourceId = this.resourceId(dto);
    const rows = await this.pg.adminQuery<PermissionRow>(
      `SELECT public.has_permission($1::uuid, $2, $3, $4, $5::jsonb, $6, $7) AS has_permission`,
      [
        dto.user.id,
        dto.resource_type,
        dto.resource_name,
        action,
        JSON.stringify(attrs),
        this.conditionsEnabled,
        resourceId,
      ],
    );
    const allow = rows[0]?.has_permission ?? false;
    const decision: PermissionDecision = {
      allow,
      reason: allow
        ? `Allowed by ${this.mode.toUpperCase()} policy`
        : `Denied by ${this.mode.toUpperCase()} policy`,
      mode: this.mode,
    };
    // RBAC mode short-circuits before mask resolution — that's the whole
    // point of the simpler mode (no JSONB conditions, no per-field masks).
    if (allow && this.mode === 'abac') {
      const mask = await this.resolveMask(
        dto.user.id,
        dto.resource_type,
        dto.resource_name,
        action,
      );
      if (mask) decision.mask = mask;
    }
    this.logger.debug(
      `${this.mode.toUpperCase()} decision user=${dto.user.id} resource=${dto.resource_type}/${dto.resource_name} op=${dto.op} allow=${allow}`,
    );
    return decision;
  }
```

**What to look at:** Configuration reads PERMISSION_MODE (rbac/abac) and PERMISSION_CONDITIONS_ENABLED (flag-gates JSONB evaluation) once at boot for hot-path efficiency.

```ts
// apps/grobase/src/apps/permission-engine/src/decisions/decisions.service.ts:42-68
@Injectable()
export class DecisionsService {
  private readonly logger = new Logger(DecisionsService.name);
  private readonly mode: PermissionMode;
  // B1: when ON, the PDP passes p_conditions_enabled=true to has_permission so
  // the stored conditions JSONB (time_window/ip_cidr/aal/owner/resource_id)
  // actually GATE a policy match. OFF (default) ⇒ has_permission ignores
  // conditions exactly as in migration 007 — byte-parity with today.
  private readonly conditionsEnabled: boolean;

  constructor(
    private readonly pg: PostgresService,
    config: ConfigService,
  ) {
    const raw = (config.get<string>('PERMISSION_MODE', 'abac') ?? 'abac').toLowerCase();
    this.mode = raw === 'rbac' ? 'rbac' : 'abac';
    // Mirror the PERMISSION_MODE pattern: a single boolean, read once at boot.
    // Conditions only make sense in abac mode (rbac has no JSONB scan at all).
    this.conditionsEnabled =
      this.mode === 'abac' &&
      ['1', 'true', 'yes', 'on'].includes(
        (config.get<string>('PERMISSION_CONDITIONS_ENABLED', '0') ?? '0').toLowerCase(),
      );
    this.logger.log(
      `DecisionsService running in mode=${this.mode} conditions=${this.conditionsEnabled ? 'on' : 'off'}`,
    );
  }
```

**What to look at:** The serialized policy bundle structure fed to Rust data-plane: active user-role bindings, all policies with priority-ordered effect and JSONB conditions.

```ts
// apps/grobase/src/apps/permission-engine/src/bundles/bundles.service.ts:29-50
export interface BundleUserRole {
  user_id: string;
  role_id: string;
  expires_at: string | null;
}

export interface BundlePolicy {
  role_id: string;
  resource_type: string;
  resource_name: string;
  actions: string[];
  effect: 'allow' | 'deny';
  priority: number;
  conditions: Record<string, unknown> | null;
}

export interface PolicyBundle {
  generated_at: string;
  user_roles: BundleUserRole[];
  policies: BundlePolicy[];
}
```

**What to look at:** Migration 007 base: 4-arg RBAC matcher joining user-roles to resource-policies, evaluating priority-ordered deny-wins logic.

```sql
-- apps/grobase/scripts/migrations/postgresql/007_permissions_system.sql:192-223
  CREATE OR REPLACE FUNCTION public.has_permission(
    p_user_id      UUID,
    p_resource_type TEXT,
    p_resource_name TEXT,
    p_action       TEXT
  ) RETURNS BOOLEAN AS $fn$
  DECLARE
    pol   RECORD;
    found BOOLEAN := false;
  BEGIN
    FOR pol IN
      SELECT rp.effect, rp.conditions
      FROM public.resource_policies rp
      JOIN public.user_roles ur ON ur.role_id = rp.role_id
      WHERE ur.user_id = p_user_id
        AND (ur.expires_at IS NULL OR ur.expires_at > now())
        AND (rp.resource_type = p_resource_type OR rp.resource_type = '*')
        AND (rp.resource_name = p_resource_name OR rp.resource_name = '*')
        AND p_action = ANY(rp.actions)
      ORDER BY rp.priority DESC, rp.effect ASC  -- deny-first at same priority
    LOOP
      -- Deny wins immediately
      IF pol.effect = 'deny' THEN
        RETURN false;
      END IF;
      found := true;
    END LOOP;

    RETURN found;
  END;
  $fn$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

**What to look at:** Migration 063 evaluator: strict on known keys (time_window, ip_cidr, aal, owner, resource_id), ignores unknown stored-row keys, returns true if all present keys pass.

```sql
-- apps/grobase/scripts/migrations/postgresql/063_permission_conditions.sql:99-195
  CREATE OR REPLACE FUNCTION auth.eval_conditions(
    p_conditions JSONB,
    p_attrs      JSONB
  ) RETURNS BOOLEAN AS $fn$
  DECLARE
    v_after   TIMESTAMPTZ;
    v_before  TIMESTAMPTZ;
    v_ip      TEXT;
    v_cidr    TEXT;
    v_match   BOOLEAN;
    v_aal_req TEXT;
    v_aal_now TEXT;
    v_owner   TEXT;
    v_uid     TEXT;
    v_rid     TEXT;
  BEGIN
    -- No conditions, or empty object ⇒ unconditionally TRUE (007 behavior).
    IF p_conditions IS NULL OR p_conditions = '{}'::jsonb THEN
      RETURN true;
    END IF;
    IF p_attrs IS NULL THEN
      p_attrs := '{}'::jsonb;
    END IF;

    -- ── time_window {after, before} vs now() ──────────────────────────
    IF p_conditions ? 'time_window' THEN
      v_after  := NULLIF(p_conditions #>> '{time_window,after}',  '');
      v_before := NULLIF(p_conditions #>> '{time_window,before}', '');
      IF v_after  IS NOT NULL AND now() <  v_after  THEN RETURN false; END IF;
      IF v_before IS NOT NULL AND now() >= v_before THEN RETURN false; END IF;
    END IF;

    -- ── ip_cidr [..] vs attrs->>'ip' via inet <<= (ANY match passes) ──
    IF p_conditions ? 'ip_cidr' THEN
      v_ip := NULLIF(p_attrs ->> 'ip', '');
      -- A required ip_cidr with NO caller ip ⇒ cannot satisfy ⇒ FALSE (strict).
      IF v_ip IS NULL THEN
        RETURN false;
      END IF;
      v_match := false;
      FOR v_cidr IN SELECT jsonb_array_elements_text(p_conditions -> 'ip_cidr') LOOP
        BEGIN
          IF inet(v_ip) <<= inet(v_cidr) OR inet(v_ip) = inet(v_cidr) THEN
            v_match := true;
            EXIT;
          END IF;
        EXCEPTION WHEN others THEN
          -- a malformed cidr/ip never silently passes — skip this entry
          CONTINUE;
        END;
      END LOOP;
      IF NOT v_match THEN RETURN false; END IF;
    END IF;

    -- ── aal "aalN": attrs aal must be >= required (lexical aal1<aal2<aal3) ─
    IF p_conditions ? 'aal' THEN
      v_aal_req := NULLIF(p_conditions ->> 'aal', '');
      v_aal_now := COALESCE(NULLIF(p_attrs ->> 'aal', ''), 'aal1');
      IF v_aal_req IS NOT NULL AND v_aal_now < v_aal_req THEN RETURN false; END IF;
    END IF;

    -- ── owner (owner:true | owner_field): attrs.user_id = attrs.owner ──
    -- owner-as-attr: the caller asserts its user_id and the resource owner are
    -- carried in attrs; the stored-row owner check is delegated to RLS, this is
    -- the request-attribute form only.
    IF (p_conditions ? 'owner') OR (p_conditions ? 'owner_field') THEN
      IF (p_conditions ->> 'owner')::text = 'true' OR (p_conditions ? 'owner_field') THEN
        v_uid   := NULLIF(p_attrs ->> 'user_id', '');
        v_owner := NULLIF(p_attrs ->> 'owner', '');
        -- Only enforce when BOTH sides are present in attrs; if the owner attr
        -- is absent the predicate is a stored-row concern (RLS) ⇒ not request-
        -- evaluable here ⇒ ignored (does not fail the policy).
        IF v_uid IS NOT NULL AND v_owner IS NOT NULL AND v_uid <> v_owner THEN
          RETURN false;
        END IF;
      END IF;
    END IF;

    -- ── resource_id / resource_id_in vs attrs->>'resource_id' ────────
    v_rid := NULLIF(p_attrs ->> 'resource_id', '');
    IF p_conditions ? 'resource_id' THEN
      IF v_rid IS NULL OR v_rid <> (p_conditions ->> 'resource_id') THEN
        RETURN false;
      END IF;
    END IF;
    IF p_conditions ? 'resource_id_in' THEN
      IF v_rid IS NULL OR NOT (
        v_rid IN (SELECT jsonb_array_elements_text(p_conditions -> 'resource_id_in'))
      ) THEN
        RETURN false;
      END IF;
    END IF;

    -- All present, request-evaluable keys satisfied (unknown keys ignored).
    RETURN true;
  END;
  $fn$ LANGUAGE plpgsql STABLE;
```

## Where it sits in the request flow

The permission engine sits between the Kong gateway (which authenticates and verifies API keys) and the query-router. Query-router is the immediate caller: it dispatches a decision request before every mutation and read. The decision comes back with allow/deny and optional field masks. If allowed, query-router forwards the request to the Rust data-plane-router (for Postgres/MySQL/MongoDB/Redis/HTTP) or the legacy TS engines, which execute the query owner-scoped by RLS or per-request filtering. The permission-engine is therefore the coarse-grained entry-point guardrail; RLS and per-request scoping are the fine-grained enforcement at the data layer.

## Remember this

> Policies are priority-ordered (deny-first at ties), conditions are strict on known keys (fail if a required time/IP/AAL/owner/resource_id is absent or doesn't match), and the engine is flag-gated off by default (PERMISSION_CONDITIONS_ENABLED=0) so the system remains byte-parity with role-only checks until explicitly enabled.

---
**See also:** [reverse_proxy.md](reverse_proxy.md) · [query-router-ApiKeyMiddleware.md](query-router-ApiKeyMiddleware.md) · [owner_isolation.md](owner_isolation.md) · [rls.md](rls.md) · [Glossary](glossary.md)

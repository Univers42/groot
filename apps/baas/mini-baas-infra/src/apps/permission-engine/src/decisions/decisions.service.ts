import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PostgresService } from '@mini-baas/database';
import { DecidePermissionDto } from './dto/decision.dto';

export interface FieldMask {
  hide?: string[];
  redact?: Record<string, string>;
}

export interface PermissionDecision {
  allow: boolean;
  reason: string;
  mask?: FieldMask;
  mode: PermissionMode;
}

interface PermissionRow {
  has_permission: boolean;
}

interface ConditionsRow {
  conditions: Record<string, unknown> | null;
}

/**
 * Permission model.
 *
 * - `abac` (default): roles match the request AND JSONB conditions on
 *   resource_policies are evaluated; field masks (hide/redact) are returned
 *   on allow.
 * - `rbac`: roles match the request; no conditions evaluated, no masks
 *   returned. Simpler, faster, no JSONB scan per request. Use when product
 *   doesn't need attribute-level decisions.
 *
 * The two modes are mutually exclusive — set `PERMISSION_MODE` once at
 * deploy time. Switching mid-stream invalidates any per-user cached
 * decisions in the query-router.
 */
export type PermissionMode = 'abac' | 'rbac';

@Injectable()
export class DecisionsService {
  private readonly logger = new Logger(DecisionsService.name);
  private readonly mode: PermissionMode;

  constructor(
    private readonly pg: PostgresService,
    config: ConfigService,
  ) {
    const raw = (config.get<string>('PERMISSION_MODE', 'abac') ?? 'abac').toLowerCase();
    this.mode = raw === 'rbac' ? 'rbac' : 'abac';
    this.logger.log(`DecisionsService running in mode=${this.mode}`);
  }

  async decide(dto: DecidePermissionDto): Promise<PermissionDecision> {
    const action = this.actionForOp(dto.op);
    const rows = await this.pg.adminQuery<PermissionRow>(
      `SELECT public.has_permission($1::uuid, $2, $3, $4) AS has_permission`,
      [dto.user.id, dto.resource_type, dto.resource_name, action],
    );
    const allow = rows[0]?.has_permission ?? false;
    const decision: PermissionDecision = {
      allow,
      reason: allow ? `Allowed by ${this.mode.toUpperCase()} policy` : `Denied by ${this.mode.toUpperCase()} policy`,
      mode: this.mode,
    };
    // RBAC mode short-circuits before mask resolution — that's the whole
    // point of the simpler mode (no JSONB conditions, no per-field masks).
    if (allow && this.mode === 'abac') {
      const mask = await this.resolveMask(dto.user.id, dto.resource_type, dto.resource_name, action);
      if (mask) decision.mask = mask;
    }
    this.logger.debug(
      `${this.mode.toUpperCase()} decision user=${dto.user.id} resource=${dto.resource_type}/${dto.resource_name} op=${dto.op} allow=${allow}`,
    );
    return decision;
  }

  private actionForOp(op: DecidePermissionDto['op']): string {
    if (op === 'list' || op === 'get') return 'select';
    if (op === 'upsert') return 'update';
    return op;
  }

  private async resolveMask(
    userId: string,
    resourceType: string,
    resourceName: string,
    action: string,
  ): Promise<FieldMask | undefined> {
    const rows = await this.pg.adminQuery<ConditionsRow>(
      `SELECT rp.conditions
         FROM public.resource_policies rp
         JOIN public.user_roles ur ON ur.role_id = rp.role_id
        WHERE ur.user_id = $1::uuid
          AND (ur.expires_at IS NULL OR ur.expires_at > now())
          AND (rp.resource_type = $2 OR rp.resource_type = '*')
          AND (rp.resource_name = $3 OR rp.resource_name = '*')
          AND $4 = ANY(rp.actions)
          AND rp.effect = 'allow'
        ORDER BY rp.priority DESC
        LIMIT 1`,
      [userId, resourceType, resourceName, action],
    );
    return this.maskFromConditions(rows[0]?.conditions);
  }

  private maskFromConditions(conditions: Record<string, unknown> | null | undefined): FieldMask | undefined {
    if (!conditions) return undefined;
    const maskValue = conditions['mask'] ?? conditions['field_mask'];
    if (!maskValue || typeof maskValue !== 'object' || Array.isArray(maskValue)) return undefined;
    const mask = maskValue as Record<string, unknown>;
    const hide = Array.isArray(mask['hide'])
      ? mask['hide'].filter((field): field is string => typeof field === 'string' && field.length > 0)
      : undefined;
    const redact = this.stringRecord(mask['redact']);
    if (!hide && !redact) return undefined;
    return { hide, redact };
  }

  private stringRecord(value: unknown): Record<string, string> | undefined {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
    const out: Record<string, string> = {};
    for (const [key, replacement] of Object.entries(value as Record<string, unknown>)) {
      if (typeof replacement === 'string') out[key] = replacement;
    }
    return Object.keys(out).length ? out : undefined;
  }
}
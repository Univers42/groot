/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   account.ts                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { routes } from '../core/routes.js';
import { HttpClient } from '../core/http.js';
import { createMemoryStorageAdapter } from '../core/storage.js';
import type { RequestOptions } from '../core/http.js';
import type {
  TenantApiKey,
  TenantApiKeyIssued,
  TenantSelfKeyCreateInput,
  TenantSelfResult,
  TenantUsage,
} from '../types.js';

/** Standalone construction: a base URL + the calling tenant's bearer token. */
export interface AccountClientOptions {
  /** Gateway base URL, e.g. `https://api.grobase.dev`. */
  baseUrl: string;
  /**
   * Bearer credential: EITHER a tenant API key OR a GoTrue user JWT. The server
   * resolves the calling tenant ("me") from this credential.
   */
  token: string;
  /** Override the global `fetch` (e.g. for Node < 18 or test doubles). */
  fetch?: typeof fetch;
  timeoutMs?: number;
}

/**
 * Tenant **self-service** control surface (`/v1/tenants/me*`).
 *
 * Unlike {@link AdminClient} (which needs an internal service-role key and hits
 * the privileged `/admin/v1/*` registry), this surface is the tenant acting on
 * *itself*: read your plan/entitlements, your usage, manage your own API keys,
 * and request a plan change. Authenticate with EITHER a tenant API key OR a
 * GoTrue user JWT — the server resolves "me" from the bearer.
 *
 * Two ways in:
 *   • via the main client — `createClient(...).account` (shares its transport;
 *     the bearer defaults to the session access token / anon key per request);
 *   • standalone — `new AccountClient({ baseUrl, token })`.
 */
export class AccountClient {
  private readonly http: HttpClient;
  /** Caller-supplied bearer (standalone mode). Undefined when wired into the
   * main client, where the shared transport supplies auth. */
  private readonly token?: string;

  constructor(http: HttpClient);
  constructor(options: AccountClientOptions);
  constructor(httpOrOptions: HttpClient | AccountClientOptions) {
    if (httpOrOptions instanceof HttpClient) {
      this.http = httpOrOptions;
      this.token = undefined;
    } else {
      const { baseUrl, token, fetch: fetchImpl, timeoutMs } = httpOrOptions;
      this.token = token;
      // Standalone transport: the bearer doubles as the `apikey` so the gateway
      // accepts a raw tenant API key (no separate publishable key needed here).
      this.http = new HttpClient({
        baseUrl,
        anonKey: token,
        fetch: fetchImpl,
        sessionStorage: createMemoryStorageAdapter(),
        timeoutMs,
      });
    }
  }

  /** GET /v1/tenants/me — the calling tenant + what its plan entitles. */
  getSelf(): Promise<TenantSelfResult> {
    return this.request<TenantSelfResult>(routes.tenantsSelf.me, 'GET');
  }

  /**
   * GET /v1/tenants/me/usage[?period=] — metered usage for a billing period.
   * `period` is server-defined (e.g. `"2026-06"`); omit for the current one.
   */
  getUsage(period?: string): Promise<TenantUsage> {
    return this.request<TenantUsage>(routes.tenantsSelf.usage(period), 'GET');
  }

  /** GET /v1/tenants/me/keys — the calling tenant's API keys (redacted). */
  listKeys(): Promise<TenantApiKey[]> {
    return this.request<TenantApiKey[]>(routes.tenantsSelf.keys, 'GET');
  }

  /**
   * POST /v1/tenants/me/keys — issue a new API key. The cleartext `key` is
   * returned **exactly once** in the response; store it now or lose it.
   */
  createKey(input: TenantSelfKeyCreateInput): Promise<TenantApiKeyIssued> {
    return this.request<TenantApiKeyIssued>(routes.tenantsSelf.keys, 'POST', input);
  }

  /** DELETE /v1/tenants/me/keys/{keyId} — revoke one of the tenant's keys. */
  revokeKey(keyId: string): Promise<{ revoked: boolean }> {
    return this.request<{ revoked: boolean }>(routes.tenantsSelf.key(keyId), 'DELETE');
  }

  /** PATCH /v1/tenants/me {plan} — request a plan change for the tenant. */
  changePlan(plan: string): Promise<TenantSelfResult> {
    return this.request<TenantSelfResult>(routes.tenantsSelf.me, 'PATCH', { plan });
  }

  private request<TResult>(path: string, method: string, body?: unknown): Promise<TResult> {
    const options: RequestOptions = { method, body };
    // Standalone mode pins the caller's bearer on every request. When wired
    // into the main client we leave auth to the shared transport (session token
    // / anon key), so a JWT-authenticated app "just works".
    if (this.token) {
      options.apiKey = this.token;
      options.bearerToken = this.token;
    }
    return this.http.request<TResult>(path, options);
  }
}

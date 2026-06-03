/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   functions.ts                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/03 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/03 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import type {
  FunctionDeployInput,
  FunctionDeployResult,
  FunctionInvokeOptions,
  FunctionSource,
  FunctionSummary,
} from '../types.js';

/**
 * Edge functions (`/functions/v1`).
 *
 * Tenants deploy TS/JS source and invoke it by name; each invocation runs in a
 * sandboxed Deno worker on the runtime. Identity is taken from the gateway's
 * JWT-derived headers, so a regular (non-admin) authenticated client works.
 *
 * Note: the gateway sets `X-User-Id` (from JWT `sub`) but not a tenant header,
 * so the runtime namespaces functions per USER, not per tenant — two users in
 * one tenant get separate function sets. An anon-key-only caller (no JWT) is
 * rejected (401).
 */
export class FunctionsClient {
  constructor(private readonly http: HttpClient) {}

  /** List the calling tenant's deployed functions. */
  list(): Promise<FunctionSummary[]> {
    return this.http.request<FunctionSummary[]>(routes.functions.root, { method: 'GET' });
  }

  /** Deploy (create or overwrite) a function's source. */
  deploy(input: FunctionDeployInput): Promise<FunctionDeployResult> {
    return this.http.request<FunctionDeployResult>(routes.functions.root, {
      method: 'POST',
      body: input,
    });
  }

  /** Fetch a function's source. */
  get(name: string): Promise<FunctionSource> {
    return this.http.request<FunctionSource>(routes.functions.one(name), { method: 'GET' });
  }

  /** Remove a deployed function. */
  delete(name: string): Promise<{ deleted: boolean }> {
    return this.http.request<{ deleted: boolean }>(routes.functions.one(name), { method: 'DELETE' });
  }

  /**
   * Invoke a deployed function by name and return its response body. The
   * runtime relays the function's own status + content type; a non-2xx status
   * surfaces as a {@link MiniBaasError}.
   */
  invoke<TResult = unknown, TPayload = unknown>(
    name: string,
    payload?: TPayload,
    options: FunctionInvokeOptions = {},
  ): Promise<TResult> {
    return this.http.request<TResult>(routes.functions.invoke(name), {
      method: options.method ?? 'POST',
      headers: options.headers,
      body: payload,
    });
  }
}

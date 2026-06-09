/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   routes.ts                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:37:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

export const routes = {
  auth: {
    token: (grantType: 'password' | 'refresh_token') => `/auth/v1/token?grant_type=${grantType}`,
    signup: '/auth/v1/signup',
    recover: '/auth/v1/recover',
    verify: '/auth/v1/verify',
    logout: '/auth/v1/logout',
    user: '/auth/v1/user',
    adminUsers: '/auth/v1/admin/users',
    adminUser: (id: string) => `/auth/v1/admin/users/${encodeURIComponent(id)}`,
    adminGenerateLink: '/auth/v1/admin/generate_link',
  },
  rest: {
    root: '/rest/v1/',
    resource: (resource: string) => `/rest/v1/${encodePath(resource)}`,
    rpc: (name: string) => `/rest/v1/rpc/${encodePath(name)}`,
  },
  query: {
    execute: '/query/v1/execute',
    txn: '/query/v1/txn',
    schema: (dbId: string) => `/query/v1/${encodeURIComponent(dbId)}/schema`,
    schemaDdl: (dbId: string) => `/query/v1/${encodeURIComponent(dbId)}/schema/ddl`,
  },
  webhooks: {
    root: '/admin/v1/webhooks',
    one: (id: string) => `/admin/v1/webhooks/${encodeURIComponent(id)}`,
    deliveries: (id: string) => `/admin/v1/webhooks/${encodeURIComponent(id)}/deliveries`,
  },
  tenants: {
    root: '/admin/v1/tenants',
    one: (id: string) => `/admin/v1/tenants/${encodeURIComponent(id)}`,
    bootstrap: (id: string) => `/admin/v1/tenants/${encodeURIComponent(id)}/bootstrap`,
    provision: '/admin/v1/provision',
  },
  migrate: {
    run: '/admin/v1/migrate',
  },
  functions: {
    root: '/functions/v1',
    one: (name: string) => `/functions/v1/${encodeURIComponent(name)}`,
    invoke: (name: string) => `/functions/v1/${encodeURIComponent(name)}/invoke`,
  },
  storage: {
    sign: (bucket: string, key: string) =>
      `/storage/v1/sign/${encodeURIComponent(bucket)}/${encodePath(key)}`,
  },
  analytics: {
    events: '/analytics/v1/events',
  },
  realtime: {
    channel: (channel: string) => `/realtime/v1/ws?channel=${encodeURIComponent(channel)}`,
    // Topic name (NOT a URL) for one table's `row_changed` stream. Compose it
    // with `client.realtimeUrl(...)` or send it in a SUBSCRIBE frame.
    tableChannel: (dbId: string, table: string) => `table:${dbId}:${table}`,
  },
} as const;

function encodePath(value: string): string {
  return value
    .split('/')
    .filter(Boolean)
    .map((part) => encodeURIComponent(part))
    .join('/');
}

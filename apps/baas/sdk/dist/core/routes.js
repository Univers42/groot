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
        token: (grantType) => `/auth/v1/token?grant_type=${grantType}`,
        signup: '/auth/v1/signup',
        recover: '/auth/v1/recover',
        verify: '/auth/v1/verify',
        logout: '/auth/v1/logout',
        user: '/auth/v1/user',
        adminUsers: '/auth/v1/admin/users',
        adminUser: (id) => `/auth/v1/admin/users/${encodeURIComponent(id)}`,
        adminGenerateLink: '/auth/v1/admin/generate_link',
    },
    rest: {
        root: '/rest/v1/',
        resource: (resource) => `/rest/v1/${encodePath(resource)}`,
        rpc: (name) => `/rest/v1/rpc/${encodePath(name)}`,
    },
    query: {
        execute: '/query/v1/execute',
        txn: '/query/v1/txn',
        schema: (dbId) => `/query/v1/${encodeURIComponent(dbId)}/schema`,
        schemaDdl: (dbId) => `/query/v1/${encodeURIComponent(dbId)}/schema/ddl`,
    },
    webhooks: {
        root: '/admin/v1/webhooks',
        one: (id) => `/admin/v1/webhooks/${encodeURIComponent(id)}`,
        deliveries: (id) => `/admin/v1/webhooks/${encodeURIComponent(id)}/deliveries`,
    },
    tenants: {
        root: '/admin/v1/tenants',
        one: (id) => `/admin/v1/tenants/${encodeURIComponent(id)}`,
        bootstrap: (id) => `/admin/v1/tenants/${encodeURIComponent(id)}/bootstrap`,
        provision: '/admin/v1/provision',
    },
    migrate: {
        run: '/admin/v1/migrate',
    },
    functions: {
        root: '/functions/v1',
        one: (name) => `/functions/v1/${encodeURIComponent(name)}`,
        invoke: (name) => `/functions/v1/${encodeURIComponent(name)}/invoke`,
    },
    storage: {
        sign: (bucket, key) => `/storage/v1/sign/${encodeURIComponent(bucket)}/${encodePath(key)}`,
    },
    analytics: {
        events: '/analytics/v1/events',
    },
    realtime: {
        channel: (channel) => `/realtime/v1/ws?channel=${encodeURIComponent(channel)}`,
        // Topic name (NOT a URL) for one table's `row_changed` stream. Compose it
        // with `client.realtimeUrl(...)` or send it in a SUBSCRIBE frame.
        tableChannel: (dbId, table) => `table:${dbId}:${table}`,
    },
};
function encodePath(value) {
    return value
        .split('/')
        .filter(Boolean)
        .map((part) => encodeURIComponent(part))
        .join('/');
}

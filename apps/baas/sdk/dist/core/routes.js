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
    },
    storage: {
        sign: (bucket, key) => `/storage/v1/sign/${encodeURIComponent(bucket)}/${encodePath(key)}`,
    },
    analytics: {
        events: '/analytics/v1/events',
    },
    realtime: {
        channel: (channel) => `/realtime/v1/ws/${encodePath(channel)}`,
    },
};
function encodePath(value) {
    return value
        .split('/')
        .filter(Boolean)
        .map((part) => encodeURIComponent(part))
        .join('/');
}

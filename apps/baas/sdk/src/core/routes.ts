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
  },
  storage: {
    sign: (bucket: string, key: string) =>
      `/storage/v1/sign/${encodeURIComponent(bucket)}/${encodePath(key)}`,
  },
  analytics: {
    events: '/analytics/v1/events',
  },
  realtime: {
    channel: (channel: string) => `/realtime/v1/ws/${encodePath(channel)}`,
  },
} as const;

function encodePath(value: string): string {
  return value
    .split('/')
    .filter(Boolean)
    .map((part) => encodeURIComponent(part))
    .join('/');
}

import { routes } from '../core/routes.js';
export class AuthClient {
    http;
    serviceRoleKey;
    admin;
    constructor(http, serviceRoleKey) {
        this.http = http;
        this.serviceRoleKey = serviceRoleKey;
        this.admin = new AuthAdminClient(http, serviceRoleKey);
    }
    async signIn(input) {
        return this.signInWithPassword(input);
    }
    async signInWithPassword(input) {
        const session = await this.http.request(routes.auth.token('password'), {
            method: 'POST',
            body: input,
            auth: false,
        });
        this.http.setSession(session);
        return session;
    }
    async signUp(input) {
        return this.http.request(routes.auth.signup, {
            method: 'POST',
            body: input,
            auth: false,
        });
    }
    async recover(input) {
        return this.http.request(routes.auth.recover, {
            method: 'POST',
            body: input,
            auth: false,
        });
    }
    async verify(input) {
        const session = await this.http.request(routes.auth.verify, {
            method: 'POST',
            body: input,
            auth: false,
        });
        if (isAuthSession(session))
            this.http.setSession(session);
        return session;
    }
    async refreshSession(refreshToken) {
        const token = refreshToken ?? this.http.getSession()?.refreshToken;
        if (!token)
            throw new Error('No refresh token available');
        const session = await this.http.request(routes.auth.token('refresh_token'), {
            method: 'POST',
            body: { refresh_token: token },
            auth: false,
        });
        this.http.setSession(session);
        return session;
    }
    async signOut() {
        await this.http.request(routes.auth.logout, { method: 'POST' });
        this.http.clearSession();
    }
    async getUser() {
        return this.http.request(routes.auth.user);
    }
    async updateUser(input, accessToken) {
        return this.http.request(routes.auth.user, {
            method: 'POST',
            body: input,
            bearerToken: accessToken,
        });
    }
    async user() {
        return this.getUser();
    }
}
export class AuthAdminClient {
    http;
    serviceRoleKey;
    constructor(http, serviceRoleKey) {
        this.http = http;
        this.serviceRoleKey = serviceRoleKey;
    }
    async createUser(input) {
        return this.request(routes.auth.adminUsers, 'POST', input);
    }
    async updateUser(id, input) {
        return this.request(routes.auth.adminUser(id), 'PATCH', input);
    }
    async generateLink(input) {
        return this.request(routes.auth.adminGenerateLink, 'POST', input);
    }
    async request(path, method, body) {
        if (!this.serviceRoleKey)
            throw new Error('Missing service role key for admin auth operation.');
        return this.http.request(path, {
            method,
            body,
            apiKey: this.serviceRoleKey,
            bearerToken: this.serviceRoleKey,
        });
    }
}
function isAuthSession(value) {
    return typeof value.access_token === 'string';
}

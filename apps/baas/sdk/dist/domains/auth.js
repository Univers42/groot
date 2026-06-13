/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
import { routes } from '../core/routes.js';
export class AuthClient {
    http;
    serviceRoleKey;
    admin;
    /** Multi-factor (TOTP / phone) enrollment + challenge/verify (gotrue). */
    mfa;
    constructor(http, serviceRoleKey) {
        this.http = http;
        this.serviceRoleKey = serviceRoleKey;
        this.admin = new AuthAdminClient(http, serviceRoleKey);
        this.mfa = new AuthMfaClient(http);
    }
    async signIn(input) {
        return this.signInWithPassword(input);
    }
    /**
     * Build the gotrue `/auth/v1/authorize` URL for a social/OIDC provider. Like
     * supabase-js, this does **not** issue a request — it returns the URL the
     * caller opens in the browser (gotrue 302s to the provider, then back to
     * `redirectTo`). The `apikey` is appended so the gateway accepts the redirect.
     */
    signInWithOAuth(input) {
        const url = this.http.buildUrl(routes.auth.authorize);
        url.searchParams.set('provider', input.provider);
        url.searchParams.set('apikey', this.http.getAnonKey());
        if (input.redirectTo)
            url.searchParams.set('redirect_to', input.redirectTo);
        if (input.scopes)
            url.searchParams.set('scopes', input.scopes);
        for (const [key, value] of Object.entries(input.queryParams ?? {})) {
            url.searchParams.set(key, value);
        }
        return { provider: input.provider, url: url.toString() };
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
/**
 * MFA helpers against gotrue's `/auth/v1/factors` surface. Enroll returns the
 * TOTP secret/QR (or registers a phone factor); challenge opens a verification
 * window; verify confirms the code and (on success) upgrades the session's AAL.
 * All three require an authenticated session (the user enrolling the factor).
 */
export class AuthMfaClient {
    http;
    constructor(http) {
        this.http = http;
    }
    async enroll(input = {}) {
        return this.http.request(routes.auth.factors, {
            method: 'POST',
            body: {
                factor_type: input.factorType ?? 'totp',
                friendly_name: input.friendlyName,
                issuer: input.issuer,
                phone: input.phone,
            },
        });
    }
    async challenge(input) {
        return this.http.request(routes.auth.factorChallenge(input.factorId), {
            method: 'POST',
            body: {},
        });
    }
    async verify(input) {
        const session = await this.http.request(routes.auth.factorVerify(input.factorId), {
            method: 'POST',
            body: { challenge_id: input.challengeId, code: input.code },
        });
        if (isAuthSession(session))
            this.http.setSession(session);
        return session;
    }
    async unenroll(factorId) {
        return this.http.request(routes.auth.factor(factorId), { method: 'DELETE' });
    }
}
function isAuthSession(value) {
    return typeof value.access_token === 'string';
}

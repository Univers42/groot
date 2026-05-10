export interface User {
    id?: string;
    email?: string;
    role?: string;
    [key: string]: unknown;
}
export interface AuthSession {
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    expires_at?: number;
    token_type?: string;
    user?: User;
    [key: string]: unknown;
}
export interface ClientSession {
    accessToken: string;
    refreshToken?: string;
    expiresAt?: number;
}
export type SessionInput = string | ClientSession | AuthSession;
export declare function normalizeSession(session: SessionInput): ClientSession;

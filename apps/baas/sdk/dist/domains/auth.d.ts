import type { AuthSession, User } from '../core/session.js';
import type { HttpClient } from '../core/http.js';
import type { AdminCreateUserInput, AdminGenerateLinkInput, AdminUpdateUserInput, MfaChallengeInput, MfaChallengeResult, MfaEnrollInput, MfaEnrollResult, MfaVerifyInput, RecoverInput, SignInWithOAuthInput, SignInWithOAuthResult, SignInWithPasswordInput, SignUpInput, UpdateUserInput, VerifyInput } from '../types.js';
export declare class AuthClient {
    private readonly http;
    private readonly serviceRoleKey?;
    readonly admin: AuthAdminClient;
    /** Multi-factor (TOTP / phone) enrollment + challenge/verify (gotrue). */
    readonly mfa: AuthMfaClient;
    constructor(http: HttpClient, serviceRoleKey?: string | undefined);
    signIn(input: SignInWithPasswordInput): Promise<AuthSession>;
    /**
     * Build the gotrue `/auth/v1/authorize` URL for a social/OIDC provider. Like
     * supabase-js, this does **not** issue a request — it returns the URL the
     * caller opens in the browser (gotrue 302s to the provider, then back to
     * `redirectTo`). The `apikey` is appended so the gateway accepts the redirect.
     */
    signInWithOAuth(input: SignInWithOAuthInput): SignInWithOAuthResult;
    signInWithPassword(input: SignInWithPasswordInput): Promise<AuthSession>;
    signUp(input: SignUpInput): Promise<AuthSession | User>;
    recover(input: RecoverInput): Promise<unknown>;
    verify(input: VerifyInput): Promise<AuthSession | User>;
    refreshSession(refreshToken?: string): Promise<AuthSession>;
    signOut(): Promise<void>;
    getUser(): Promise<User>;
    updateUser(input: UpdateUserInput, accessToken?: string): Promise<User>;
    user(): Promise<User>;
}
export declare class AuthAdminClient {
    private readonly http;
    private readonly serviceRoleKey?;
    constructor(http: HttpClient, serviceRoleKey?: string | undefined);
    createUser(input: AdminCreateUserInput): Promise<User>;
    updateUser(id: string, input: AdminUpdateUserInput): Promise<User>;
    generateLink(input: AdminGenerateLinkInput): Promise<Record<string, unknown>>;
    private request;
}
/**
 * MFA helpers against gotrue's `/auth/v1/factors` surface. Enroll returns the
 * TOTP secret/QR (or registers a phone factor); challenge opens a verification
 * window; verify confirms the code and (on success) upgrades the session's AAL.
 * All three require an authenticated session (the user enrolling the factor).
 */
export declare class AuthMfaClient {
    private readonly http;
    constructor(http: HttpClient);
    enroll(input?: MfaEnrollInput): Promise<MfaEnrollResult>;
    challenge(input: MfaChallengeInput): Promise<MfaChallengeResult>;
    verify(input: MfaVerifyInput): Promise<AuthSession>;
    unenroll(factorId: string): Promise<unknown>;
}

import type { AuthSession, User } from '../core/session.js';
import type { HttpClient } from '../core/http.js';
import type { AdminCreateUserInput, AdminGenerateLinkInput, AdminUpdateUserInput, RecoverInput, SignInWithPasswordInput, SignUpInput, UpdateUserInput, VerifyInput } from '../types.js';
export declare class AuthClient {
    private readonly http;
    private readonly serviceRoleKey?;
    readonly admin: AuthAdminClient;
    constructor(http: HttpClient, serviceRoleKey?: string | undefined);
    signIn(input: SignInWithPasswordInput): Promise<AuthSession>;
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

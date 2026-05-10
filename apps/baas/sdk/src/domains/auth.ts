import { routes } from '../core/routes.js';
import type { AuthSession, User } from '../core/session.js';
import type { HttpClient } from '../core/http.js';
import type {
  AdminCreateUserInput,
  AdminGenerateLinkInput,
  AdminUpdateUserInput,
  RecoverInput,
  SignInWithPasswordInput,
  SignUpInput,
  UpdateUserInput,
  VerifyInput,
} from '../types.js';

export class AuthClient {
  readonly admin: AuthAdminClient;

  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {
    this.admin = new AuthAdminClient(http, serviceRoleKey);
  }

  async signIn(input: SignInWithPasswordInput): Promise<AuthSession> {
    return this.signInWithPassword(input);
  }

  async signInWithPassword(input: SignInWithPasswordInput): Promise<AuthSession> {
    const session = await this.http.request<AuthSession>(routes.auth.token('password'), {
      method: 'POST',
      body: input,
      auth: false,
    });

    this.http.setSession(session);
    return session;
  }

  async signUp(input: SignUpInput): Promise<AuthSession | User> {
    return this.http.request<AuthSession | User>(routes.auth.signup, {
      method: 'POST',
      body: input,
      auth: false,
    });
  }

  async recover(input: RecoverInput): Promise<unknown> {
    return this.http.request(routes.auth.recover, {
      method: 'POST',
      body: input,
      auth: false,
    });
  }

  async verify(input: VerifyInput): Promise<AuthSession | User> {
    const session = await this.http.request<AuthSession | User>(routes.auth.verify, {
      method: 'POST',
      body: input,
      auth: false,
    });

    if (isAuthSession(session)) this.http.setSession(session);
    return session;
  }

  async refreshSession(refreshToken?: string): Promise<AuthSession> {
    const token = refreshToken ?? this.http.getSession()?.refreshToken;
    if (!token) throw new Error('No refresh token available');

    const session = await this.http.request<AuthSession>(routes.auth.token('refresh_token'), {
      method: 'POST',
      body: { refresh_token: token },
      auth: false,
    });

    this.http.setSession(session);
    return session;
  }

  async signOut(): Promise<void> {
    await this.http.request<void>(routes.auth.logout, { method: 'POST' });
    this.http.clearSession();
  }

  async getUser(): Promise<User> {
    return this.http.request<User>(routes.auth.user);
  }

  async updateUser(input: UpdateUserInput, accessToken?: string): Promise<User> {
    return this.http.request<User>(routes.auth.user, {
      method: 'POST',
      body: input,
      bearerToken: accessToken,
    });
  }

  async user(): Promise<User> {
    return this.getUser();
  }
}

export class AuthAdminClient {
  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {}

  async createUser(input: AdminCreateUserInput): Promise<User> {
    return this.request<User>(routes.auth.adminUsers, 'POST', input);
  }

  async updateUser(id: string, input: AdminUpdateUserInput): Promise<User> {
    return this.request<User>(routes.auth.adminUser(id), 'PATCH', input);
  }

  async generateLink(input: AdminGenerateLinkInput): Promise<Record<string, unknown>> {
    return this.request<Record<string, unknown>>(routes.auth.adminGenerateLink, 'POST', input);
  }

  private async request<TResult>(path: string, method: string, body: unknown): Promise<TResult> {
    if (!this.serviceRoleKey) throw new Error('Missing service role key for admin auth operation.');
    return this.http.request<TResult>(path, {
      method,
      body,
      apiKey: this.serviceRoleKey,
      bearerToken: this.serviceRoleKey,
    });
  }
}

function isAuthSession(value: AuthSession | User): value is AuthSession {
  return typeof (value as AuthSession).access_token === 'string';
}

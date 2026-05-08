import { authConfig } from '../lib/auth-config';

const EMAIL_ATEXT = "A-Za-z0-9!#$%&'*+/=?^_`{|}~-";
const EMAIL_LOCAL_PART = String.raw`(?:[${EMAIL_ATEXT}]+(?:\.[${EMAIL_ATEXT}]+)*|"[^"\r\n]+")`;
const EMAIL_DOMAIN_LABEL = '(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)';
export const RFC_5322_EMAIL_REGEX = new RegExp(String.raw`^${EMAIL_LOCAL_PART}@(?:${EMAIL_DOMAIN_LABEL}\.)+[A-Za-z]{2,63}$`);
export const STRONG_PASSWORD_REGEX = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$/;

export type AuthMode = 'login' | 'register';

export type AuthRequest = {
	email: string;
	password: string;
	turnstileToken: string;
};

export type RegisterProfile = {
	username: string;
	confirmPassword: string;
	emailVerificationConsent?: boolean;
	newsletterConsent?: boolean;
	notificationsEnabled?: boolean;
};

export type RegisterRequest = AuthRequest & {
	profile: RegisterProfile;
};

export type RecoverRequest = {
	email: string;
	turnstileToken: string;
};

export type AuthResult = {
	ok: boolean;
	status: number;
	message: string;
	accessToken?: string;
	expiresIn?: number;
};

export type AvailabilityFieldResult = {
	checked: boolean;
	available: boolean | null;
	message: string;
};

export type AvailabilityResult = {
	email: AvailabilityFieldResult;
	username: AvailabilityFieldResult;
};

type AuthClientOptions = {
	gatewayUrl?: string;
	maxRetries?: number;
};

function normalizeGatewayUrl(url: string): string {
	return url.replace(/\/$/, '');
}

export function validateEmail(email: string): boolean {
	return RFC_5322_EMAIL_REGEX.test(email.trim());
}

export function validatePassword(password: string): boolean {
	return STRONG_PASSWORD_REGEX.test(password);
}

function validationMessage(request: AuthRequest, mode: AuthMode): string | null {
	if (!validateEmail(request.email)) {
		return 'Use a valid email address.';
	}
	if (mode === 'register' && !validatePassword(request.password)) {
		return 'Password must be at least 8 characters and include uppercase, lowercase, number, and symbol.';
	}
	if (mode === 'login' && request.password.length === 0) {
		return 'Enter your password.';
	}
	if (!request.turnstileToken) {
		return 'Complete the anti-abuse check.';
	}
	return null;
}

function registrationValidationMessage(request: RegisterRequest): string | null {
	const baseError = validationMessage(request, 'register');
	if (baseError) {
		return baseError;
	}
	if (!/^\w[\w.-]{2,31}$/.test(request.profile.username.trim())) {
		return 'Choose a username with 3–32 letters, numbers, dots, underscores, or hyphens.';
	}
	if (request.password !== request.profile.confirmPassword) {
		return 'Password confirmation must match.';
	}
	if (authConfig.requireEmailVerification && request.profile.emailVerificationConsent === false) {
		return 'Email verification must stay enabled for account security.';
	}
	return null;
}

async function delay(ms: number): Promise<void> {
	await new Promise((resolve) => globalThis.setTimeout(resolve, ms));
}

function randomJitter(maxExclusive: number): number {
	const values = new Uint32Array(1);
	globalThis.crypto.getRandomValues(values);
	return (values[0] / 0x100000000) * maxExclusive;
}

async function parseAuthResponse(response: Response): Promise<AuthResult> {
	const payload = await response.json().catch(() => ({})) as Record<string, unknown>;
	let message = 'Request failed.';
	if (typeof payload.error_description === 'string') {
		message = payload.error_description;
	} else if (typeof payload.msg === 'string') {
		message = payload.msg;
	} else if (typeof payload.message === 'string') {
		message = payload.message;
	} else if (typeof payload.error === 'string') {
		message = payload.error;
	} else if (response.ok) {
		message = 'Request completed.';
	}
	return {
		ok: response.ok,
		status: response.status,
		message,
		accessToken: typeof payload.access_token === 'string' ? payload.access_token : undefined,
		expiresIn: typeof payload.expires_in === 'number' ? payload.expires_in : undefined,
	};
}

async function parseAvailabilityResponse(response: Response): Promise<AvailabilityResult> {
	const payload = await response.json().catch(() => ({})) as Partial<AvailabilityResult>;
	return {
		email: payload.email ?? { checked: false, available: null, message: 'Email availability could not be checked.' },
		username: payload.username ?? { checked: false, available: null, message: 'Username availability could not be checked.' },
	};
}

async function fetchWithBackoff(url: string, init: RequestInit, maxRetries: number): Promise<Response> {
	let attempt = 0;
	for (;;) {
		const response = await fetch(url, init);
		if (response.status !== 429 || attempt >= maxRetries) {
			return response;
		}
		const retryAfter = Number(response.headers.get('retry-after'));
		const baseDelay = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 400 * 2 ** attempt;
		await delay(Math.min(baseDelay + randomJitter(150), 5000));
		attempt += 1;
	}
}

export function useAuth(options: AuthClientOptions = {}) {
	const gatewayUrl = normalizeGatewayUrl(options.gatewayUrl ?? authConfig.gatewayUrl);
	const maxRetries = options.maxRetries ?? 3;
	const post = async (path: string, body: Record<string, unknown>): Promise<Response> => fetchWithBackoff(`${gatewayUrl}${path}`, {
		method: 'POST',
		headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
		credentials: 'include',
		body: JSON.stringify(body),
	}, maxRetries);

	return {
		validateEmail,
		validatePassword,
		async availability(email: string, username: string): Promise<AvailabilityResult> {
			const params = new URLSearchParams();
			if (email.trim()) {
				params.set('email', email.trim());
			}
			if (username.trim()) {
				params.set('username', username.trim());
			}
			return parseAvailabilityResponse(await fetchWithBackoff(`${gatewayUrl}/availability?${params}`, {
				method: 'GET',
				headers: { Accept: 'application/json' },
				credentials: 'include',
			}, maxRetries));
		},
		async signIn(request: AuthRequest): Promise<AuthResult> {
			const error = validationMessage(request, 'login');
			if (error) {
				return { ok: false, status: 422, message: error };
			}
			return parseAuthResponse(await post('/login', request));
		},
		async register(request: RegisterRequest): Promise<AuthResult> {
			const error = registrationValidationMessage(request);
			if (error) {
				return { ok: false, status: 422, message: error };
			}
			return parseAuthResponse(await post('/register', request));
		},
		async recover(request: RecoverRequest): Promise<AuthResult> {
			if (!validateEmail(request.email)) {
				return { ok: false, status: 422, message: 'Use a valid email address.' };
			}
			if (!request.turnstileToken) {
				return { ok: false, status: 422, message: 'Complete the anti-abuse check.' };
			}
			return parseAuthResponse(await post('/recover', request));
		},
		async refresh(): Promise<AuthResult> {
			return parseAuthResponse(await post('/refresh', {}));
		},
		async logout(): Promise<AuthResult> {
			return parseAuthResponse(await post('/logout', {}));
		},
		async beginMfaTotpEnrollment(): Promise<AuthResult> {
			return parseAuthResponse(await post('/mfa/totp/enroll', {}));
		},
		async verifyMfaTotp(code: string): Promise<AuthResult> {
			return parseAuthResponse(await post('/mfa/totp/verify', { code }));
		},
		async beginWebAuthn(): Promise<AuthResult> {
			return parseAuthResponse(await post('/mfa/webauthn/options', {}));
		},
	};
}

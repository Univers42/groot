import { MiniBaasError } from '@mini-baas/js';
import { createPublicBaasClient, fetchSeededUsers } from '../lib/baas-client';
import { authConfig } from '../lib/auth-config';
import { type AuthResult, type AvailabilityFieldResult, type RegisterProfile, useAuth, validateEmail, validatePassword } from '../hooks/useAuth';
import { CONSENT_STORAGE_KEY, CSRF_STORAGE_KEY, NEWSLETTER_INTENT_KEY, POLICY_VERSION } from '../data/legal';
import { type NotificationKind, type NotificationOptions, dismissAll, notify } from './notifications';
import { checkPasswordStrength, passwordRuleResults } from './password-strength';

type ThemeName = 'aurora' | 'solar' | 'ember' | 'forest';

type PortalMode = 'start' | 'connect';

type MascotMood = 'curious' | 'close' | 'gentle' | 'happy' | 'excited' | 'listening' | 'sleeping' | 'bye' | 'thinking' | 'shy' | 'proud' | 'seller' | 'laughing' | 'silly' | 'surprised' | 'scared' | 'love' | 'angry' | 'dizzy';

type MascotState = {
	targetX: number;
	targetY: number;
	targetHeadX: number;
	targetHeadY: number;
	depthX: number;
	depthY: number;
	eyeX: number;
	eyeY: number;
	headX: number;
	headY: number;
	lastPointerAngle: number | undefined;
	orbitTravel: number;
	lastBrowLift: number;
	lastMove: number;
	lockedUntil: number;
	idleMoodShown: boolean;
	moodTimer: number | undefined;
	heartTimer: number | undefined;
	zTimer: number | undefined;
	laughTimer: number | undefined;
	frame: number | undefined;
	previousFocus: HTMLElement | null;
	releaseFocusTrap: (() => void) | null;
};

type ConsentPreferences = {
	analytics: boolean;
	newsletter: boolean;
	marketing: boolean;
	policyVersion: string;
	savedAt: string;
};

type TurnstileApi = {
	render: (container: HTMLElement, options: { sitekey: string; callback: (token: string) => void; 'error-callback': () => void; 'expired-callback': () => void }) => string;
	reset?: (widgetId?: string) => void;
};

type TrustedHtmlPolicy = {
	createHTML: (markup: string) => unknown;
};

type TrustedTypesFactory = {
	createPolicy: (name: string, rules: { createHTML: (markup: string) => string }) => TrustedHtmlPolicy;
};

type AuthModeControls = {
	authTitle: Element | null;
	authNote: Element | null;
	submitButton: Element | null;
	termsConsent: Element | null;
	email: Element | null;
	username: Element | null;
	emailVerificationConsent: Element | null;
	password: Element | null;
	confirmPassword: Element | null;
};

declare global {
	var turnstile: TurnstileApi | undefined;
}

const THEME_KEY = 'prismatica-theme';
const MOTION_KEY = 'prismatica-motion-paused';
const AUTH_TOKEN_KEY = 'prismatica-auth-token-v1';

function secureRandom(): number {
	const values = new Uint32Array(1);
	globalThis.crypto.getRandomValues(values);
	return values[0] / 0x100000000;
}

function randomBetween(minimum: number, span: number): number {
	return minimum + secureRandom() * span;
}

function randomIndex(length: number): number {
	return Math.floor(secureRandom() * length);
}
const THEMES: ThemeName[] = ['aurora', 'solar', 'ember', 'forest'];
const authClient = useAuth();
const COMMON_EMAIL_DOMAINS = ['gmail.com', 'outlook.com', 'hotmail.com', 'icloud.com', 'yahoo.com', 'proton.me', 'protonmail.com', 'live.com'];
const EMAIL_DOMAIN_ALIASES: Record<string, string> = {
	'gmail.con': 'gmail.com',
	'gmail.co': 'gmail.com',
	'gamil.com': 'gmail.com',
	'gmial.com': 'gmail.com',
	'gnail.com': 'gmail.com',
	'hotmai.com': 'hotmail.com',
	'hotmail.con': 'hotmail.com',
	'outlok.com': 'outlook.com',
	'outlook.con': 'outlook.com',
	'icloud.con': 'icloud.com',
	'yaho.com': 'yahoo.com',
	'yahoo.con': 'yahoo.com',
};
let trustedHtmlPolicy: TrustedHtmlPolicy | null | undefined;
const mascotState: MascotState = {
	targetX: 0,
	targetY: 0,
	targetHeadX: 0,
	targetHeadY: 0,
	depthX: 5,
	depthY: 4,
	eyeX: 0,
	eyeY: 0,
	headX: 0,
	headY: 0,
	lastPointerAngle: undefined,
	orbitTravel: 0,
	lastBrowLift: 0,
	lastMove: Date.now(),
	lockedUntil: 0,
	idleMoodShown: false,
	moodTimer: undefined,
	heartTimer: undefined,
	zTimer: undefined,
	laughTimer: undefined,
	frame: undefined,
	previousFocus: null,
	releaseFocusTrap: null,
};

/** Returns an internal TrustedHTML value when the browser enforces Trusted Types. */
function trustedHTML(markup: string): unknown {
	if (trustedHtmlPolicy === undefined) {
		const trustedTypes = (globalThis as typeof globalThis & { trustedTypes?: TrustedTypesFactory }).trustedTypes;
		try {
			trustedHtmlPolicy = trustedTypes?.createPolicy('prismatica-static-markup', { createHTML: (value) => value }) ?? null;
		} catch {
			trustedHtmlPolicy = null;
		}
	}
	return trustedHtmlPolicy ? trustedHtmlPolicy.createHTML(markup) : markup;
}

/** Assigns static internal markup through Trusted Types-aware DOM sinks. */
function setTrustedInnerHTML(element: HTMLElement, markup: string): void {
	(element as unknown as { innerHTML: unknown }).innerHTML = trustedHTML(markup);
}

/** Inserts static internal markup through Trusted Types-aware DOM sinks. */
function insertTrustedHTML(element: HTMLElement, position: InsertPosition, markup: string): void {
	element.insertAdjacentHTML(position, trustedHTML(markup) as string);
}

/** Restricts a number to the expected animation range. */
function clamp(value: number, min: number, max: number): number {
	return Math.min(Math.max(value, min), max);
}

/** Returns an element when it matches the expected runtime type. */
function queryElement<T extends Element>(selector: string, guard: (element: Element) => element is T): T | null {
	const element = document.querySelector(selector);
	return element && guard(element) ? element : null;
}


/** Returns all elements matching the expected runtime type. */
function queryElements<T extends Element>(selector: string, guard: (element: Element) => element is T): T[] {
	return Array.from(document.querySelectorAll(selector)).filter(guard);
}

/** Narrows an element to an HTML button. */
function isButton(element: Element): element is HTMLButtonElement {
	return element instanceof HTMLButtonElement;
}

/** Narrows an element to a generic HTML element. */
function isHtmlElement(element: Element): element is HTMLElement {
	return element instanceof HTMLElement;
}

/** Narrows an element to an input field. */
function isInput(element: Element): element is HTMLInputElement {
	return element instanceof HTMLInputElement;
}

/** Returns the current Turnstile token or a localhost bypass token when configured. */
function readTurnstileToken(portal: HTMLElement): string {
	const token = portal.querySelector('[data-turnstile-token]');
	if (token instanceof HTMLInputElement && token.value) {
		return token.value;
	}
	return authConfig.turnstileSiteKey ? '' : 'localhost-turnstile-token';
}

/** Renders the Cloudflare Turnstile widget into the active auth portal. */
function mountTurnstile(portal: HTMLElement): void {
	const container = portal.querySelector('[data-turnstile-widget]');
	const token = portal.querySelector('[data-turnstile-token]');
	if (!(container instanceof HTMLElement) || !(token instanceof HTMLInputElement)) {
		return;
	}
	if (!authConfig.turnstileSiteKey) {
		token.value = 'localhost-turnstile-token';
		container.hidden = true;
		return;
	}
	const render = (): void => {
		if (!globalThis.turnstile || container.dataset.widgetId) {
			return;
		}
		container.dataset.widgetId = globalThis.turnstile.render(container, {
			sitekey: authConfig.turnstileSiteKey,
			callback: (value: string) => {
				token.value = value;
			},
			'error-callback': () => {
				token.value = '';
			},
			'expired-callback': () => {
				token.value = '';
			},
		});
	};
	render();
	if (!container.dataset.widgetId) {
		globalThis.setTimeout(render, 600);
	}
}

/** Safely reads a persisted value. */
function readStorage(key: string): string | null {
	try {
		return globalThis.localStorage.getItem(key);
	} catch {
		return null;
	}
}

/** Safely writes a persisted value. */
function writeStorage(key: string, value: string): void {
	try {
		globalThis.localStorage.setItem(key, value);
	} catch {
		return;
	}
}

function isThemeName(value: string | null | undefined): value is ThemeName {
	return value === 'aurora' || value === 'solar' || value === 'ember' || value === 'forest';
}

function normalizeTheme(value: string | null): ThemeName | null {
	if (isThemeName(value)) {
		return value;
	}
	if (value === 'light') {
		return 'solar';
	}
	if (value === 'dark' || value === 'night') {
		return 'aurora';
	}
	return null;
}

/** Chooses the initial theme from storage or system preference. */
function initialTheme(): ThemeName {
	return normalizeTheme(readStorage(THEME_KEY)) ?? (globalThis.matchMedia('(prefers-color-scheme: dark)').matches ? 'aurora' : 'solar');
}

/** Returns the compact icon for the selected theme. */
function themeIcon(theme: ThemeName): string {
	const icons: Record<ThemeName, string> = {
		aurora: '✦',
		solar: '☼',
		ember: '◒',
		forest: '◆',
	};
	return icons[theme];
}

function themeDisplayName(theme: ThemeName): string {
	const labels: Record<ThemeName, string> = {
		aurora: 'Aurora',
		solar: 'Solar',
		ember: 'Ember',
		forest: 'Forest',
	};
	return labels[theme];
}

/** Updates visible and assistive theme button labels. */
function updateThemeButton(theme: ThemeName): void {
	const buttons = queryElements('#theme-toggle, [data-theme-toggle]', isButton);
	const labels = queryElements('[data-theme-label]', isHtmlElement);
	const nextTheme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length] ?? 'aurora';
	const themeLabel = themeDisplayName(theme);
	const nextLabel = themeDisplayName(nextTheme);
	buttons.forEach((button) => {
		button.setAttribute('aria-label', `Theme: ${themeLabel}. Switch to ${nextLabel} palette`);
		button.title = `Switch to ${nextLabel} theme`;
		const icon = button.querySelector('.header-icon--theme');
		if (icon instanceof HTMLElement) {
			icon.textContent = themeIcon(theme);
		}
	});
	labels.forEach((label) => {
		label.textContent = `Theme: ${themeLabel}`;
	});
}

/** Applies a theme to the document root. */
function applyTheme(theme: ThemeName): void {
	document.documentElement.dataset.theme = theme;
	document.documentElement.style.colorScheme = theme === 'solar' ? 'light' : 'dark';
	writeStorage(THEME_KEY, theme);
	updateThemeButton(theme);
}

/** Advances the current theme. */
function cycleTheme(): void {
	const current = normalizeTheme(document.documentElement.dataset.theme ?? null);
	const index = current ? THEMES.indexOf(current) : -1;
	const nextTheme = THEMES[(index + 1) % THEMES.length] ?? 'aurora';
	applyTheme(nextTheme);
	announce(`${themeDisplayName(nextTheme)} theme enabled`);
}

/** Updates visible and assistive motion button labels. */
function updateMotionButton(paused: boolean): void {
	const button = queryElement('#pause-animations', isButton);
	const label = queryElement('[data-motion-label]', isHtmlElement);
	if (button) {
		button.setAttribute('aria-pressed', String(paused));
		button.setAttribute('aria-label', paused ? 'Resume animations' : 'Pause animations');
		button.title = paused ? 'Resume animations' : 'Pause animations';
		const icon = button.querySelector('.header-icon--motion');
		if (icon instanceof HTMLElement) {
			icon.textContent = paused ? '▶' : 'Ⅱ';
		}
	}
	if (label) {
		label.textContent = paused ? 'Resume animations' : 'Pause animations';
	}
}

/** Applies the motion preference to the page. */
function applyMotionPreference(paused: boolean): void {
	document.documentElement.classList.toggle('motion-paused', paused);
	writeStorage(MOTION_KEY, paused ? 'true' : 'false');
	updateMotionButton(paused);
	announce(paused ? 'Animations paused' : 'Animations resumed');
}

/** Ensures every button has an accessible name, even if a future edit forgets one. */
function ensureButtonLabels(): void {
	queryElements('button', (element): element is HTMLButtonElement => element instanceof HTMLButtonElement).forEach((button) => {
		if (button.getAttribute('aria-label') || button.getAttribute('aria-labelledby')) {
			return;
		}
		const label = (button.textContent ?? '').replaceAll(/\s+/g, ' ').trim() || button.title.trim();
		if (label) {
			button.setAttribute('aria-label', label);
		}
	});
}

function bindPasswordToggles(root: ParentNode = document): void {
	Array.from(root.querySelectorAll('[data-password-toggle]')).forEach((toggle) => {
		if (!(toggle instanceof HTMLButtonElement) || toggle.dataset.passwordToggleBound === 'true') return;
		const inputId = toggle.getAttribute('aria-controls');
		const input = inputId ? root.querySelector(`#${CSS.escape(inputId)}`) : null;
		if (!(input instanceof HTMLInputElement)) return;
		toggle.dataset.passwordToggleBound = 'true';
		toggle.addEventListener('click', () => {
			const show = input.type === 'password';
			input.type = show ? 'text' : 'password';
			toggle.setAttribute('aria-pressed', String(show));
			const targetName = toggle.dataset.passwordTargetName ?? toggle.getAttribute('aria-label')?.replace(/^(Show|Hide)\s+/i, '') ?? 'password';
			const nextVerb = show ? 'Hide' : 'Show';
			toggle.dataset.passwordTargetName = targetName;
			toggle.setAttribute('aria-label', `${nextVerb} ${targetName}`);
			toggle.title = `${nextVerb} ${targetName}`;
			const icon = toggle.querySelector('[aria-hidden="true"]');
			if (icon instanceof HTMLElement) icon.textContent = show ? '◎' : '◉';
			input.focus({ preventScroll: true });
		});
	});
}

/** Draws a subtle paper grain on the decorative canvas. */
function renderPaperGrain(): void {
	const canvas = queryElement('#paper-grain', (element): element is HTMLCanvasElement => element instanceof HTMLCanvasElement);
	if (!canvas) {
		return;
	}
	const context = canvas.getContext('2d');
	if (!context) {
		return;
	}
	const ratio = Math.min(window.devicePixelRatio || 1, 2);
	canvas.width = Math.floor(window.innerWidth * ratio);
	canvas.height = Math.floor(window.innerHeight * ratio);
	canvas.style.width = `${window.innerWidth}px`;
	canvas.style.height = `${window.innerHeight}px`;
	context.setTransform(ratio, 0, 0, ratio, 0, 0);
	context.clearRect(0, 0, window.innerWidth, window.innerHeight);
	for (let index = 0; index < 900; index += 1) {
		const alpha = secureRandom() * 0.05;
		context.fillStyle = `rgba(28, 22, 18, ${alpha})`;
		context.fillRect(secureRandom() * window.innerWidth, secureRandom() * window.innerHeight, randomBetween(0.4, 1.8), randomBetween(0.4, 1.8));
	}
}

/** Announces dynamic state changes to assistive technology. */
function announce(message: string): void {
	const announcer = queryElement('#global-announcer', isHtmlElement);
	if (announcer) {
		announcer.textContent = message;
	}
}

/** Reads the current demo auth token for authenticated RPC calls. */
function readAuthToken(): string | null {
	return readStorage(AUTH_TOKEN_KEY);
}

type RpcStatus = {
	ok: boolean;
	status: number;
};

/** Calls a GDPR RPC with either the user's token or the anon key. */
async function callGdprRpc(name: string, body: Record<string, unknown>, token = readAuthToken()): Promise<RpcStatus> {
	try {
		await createPublicBaasClient(token ?? undefined).rpc(name, body);
		return { ok: true, status: 200 };
	} catch (error) {
		if (error instanceof MiniBaasError) return { ok: false, status: error.status };
		throw error;
	}
}

/** Authenticates a portal login through the public BaaS gateway. */
async function authenticatePortalLogin(email: string, password: string, turnstileToken: string): Promise<AuthResult> {
	const payload = await authClient.signIn({ email, password, turnstileToken });
	if (payload.ok && typeof payload.accessToken === 'string' && payload.accessToken.length > 0) {
		writeStorage(AUTH_TOKEN_KEY, payload.accessToken);
	}
	return payload;
}

/** Registers a portal account through the Turnstile-protected auth gateway. */
async function registerPortalAccount(email: string, password: string, turnstileToken: string, profile: RegisterProfile): Promise<AuthResult> {
	const payload = await authClient.register({ email, password, turnstileToken, profile });
	return payload;
}

/** Requests a password recovery email without revealing whether the account exists. */
async function requestPasswordRecovery(email: string, turnstileToken: string): Promise<void> {
	const response = await authClient.recover({ email, turnstileToken });
	if (!response.ok && response.status >= 500) {
		throw new Error('Password recovery service is unavailable.');
	}
}

async function requestNewsletterSubscription(email: string): Promise<AuthResult> {
	const response = await fetch('/api/newsletter/subscribe', {
		method: 'POST',
		headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
		body: JSON.stringify({ email: email.trim() }),
	});
	const payload = await response.json().catch(() => ({})) as { message?: string; error?: string };
	return {
		ok: response.ok,
		status: response.status,
		message: payload.message ?? payload.error ?? (response.ok ? 'Check your inbox to confirm your subscription.' : 'Could not send the newsletter confirmation email.'),
	};
}

/** Persists consent preferences locally when no user token exists yet. */
function storeConsentPreferences(preferences: Omit<ConsentPreferences, 'policyVersion' | 'savedAt'>): ConsentPreferences {
	const record: ConsentPreferences = {
		...preferences,
		policyVersion: POLICY_VERSION,
		savedAt: new Date().toISOString(),
	};
	writeStorage(CONSENT_STORAGE_KEY, JSON.stringify(record));
	return record;
}

/** Reads locally stored consent preferences. */
function readConsentPreferences(): ConsentPreferences | null {
	const raw = readStorage(CONSENT_STORAGE_KEY);
	if (!raw) {
		return null;
	}
	try {
		return JSON.parse(raw) as ConsentPreferences;
	} catch {
		return null;
	}
}

/** Synchronises locally stored newsletter consent after login when possible. */
async function syncStoredConsents(_token: string, email?: string): Promise<void> {
	const preferences = readConsentPreferences();
	if (preferences?.newsletter && email) {
		await requestNewsletterSubscription(email).catch(() => undefined);
	}

	const newsletterIntent = readStorage(NEWSLETTER_INTENT_KEY);
	if (newsletterIntent && email) {
		await requestNewsletterSubscription(email).catch(() => undefined);
		localStorage.removeItem(NEWSLETTER_INTENT_KEY);
	}
}

/** Returns the full original Binocle mascot SVG structure with tubes, barrels and expression layers. */
function mascotSvgMarkup(): string {
	return `
		<svg class="binocle__svg" viewBox="0 0 184 118" role="img" aria-labelledby="binocle-title binocle-desc">
			<title id="binocle-title">Prismatica mascot</title>
			<desc id="binocle-desc">Living binocular mascot with tracking pupils, expressive brows and an animated mouth.</desc>
			<g class="svg-body-group">
				<path class="svg-arm left" d="M49 31 C39 18, 25 18, 19 32" />
				<path class="svg-arm right" d="M135 31 C147 18, 161 19, 166 33" />
				<g class="svg-volume">
					<path class="svg-shell left" d="M15 34 C26 20, 51 16, 69 27 C80 34, 87 48, 86 62 C85 78, 73 90, 55 94 C34 98, 14 90, 7 75 C1 61, 4 45, 15 34Z" />
					<path class="svg-shell right" d="M115 27 C134 16, 158 20, 169 34 C180 49, 183 65, 177 78 C170 92, 150 98, 129 94 C111 90, 99 78, 98 62 C97 48, 104 34, 115 27Z" />
					<ellipse class="svg-back" cx="51" cy="61" rx="39" ry="34" />
					<ellipse class="svg-back" cx="145" cy="61" rx="39" ry="34" />
				</g>
				<path class="svg-barrel left" d="M20 39 C29 28, 47 25, 62 32 C50 29, 33 32, 24 43 C16 54, 16 67, 24 77 C12 69, 9 51, 20 39Z" />
				<path class="svg-barrel right" d="M122 32 C136 25, 154 28, 164 39 C175 51, 172 69, 160 77 C168 67, 168 54, 160 43 C151 32, 134 29, 122 32Z" />
				<ellipse class="svg-frame left-frame" cx="43" cy="57" rx="39" ry="34" />
				<ellipse class="svg-frame right-frame" cx="141" cy="57" rx="39" ry="34" />
				<ellipse class="svg-inner-rim" cx="43" cy="57" rx="28" ry="24" />
				<ellipse class="svg-inner-rim" cx="141" cy="57" rx="28" ry="24" />
				<ellipse class="svg-rim" cx="38" cy="53" rx="24" ry="20" />
				<ellipse class="svg-rim" cx="136" cy="53" rx="24" ry="20" />
				<path class="svg-center-band" d="M84 53 C88 48, 96 48, 100 53" />
				<path class="svg-center-band" d="M86 67 C90 71, 95 71, 99 67" />
				<path class="svg-bridge-shadow" d="M99 62 C103 54, 110 54, 114 62" />
				<path class="svg-bridge" d="M80 61 C84 51, 91 48, 97 52 C101 55, 104 59, 108 62 C110 63, 112 63, 114 62" />
				<path class="svg-detail" d="M16 55 C20 34, 36 24, 56 28" />
				<path class="svg-detail" d="M19 62 C21 76, 35 86, 52 85" />
				<path class="svg-detail" d="M118 28 C139 23, 158 34, 164 55" />
				<path class="svg-detail" d="M162 63 C159 78, 145 86, 129 84" />
				<path class="svg-stitch" d="M28 80 C40 86, 57 85, 67 77" />
				<path class="svg-stitch" d="M123 77 C134 86, 152 85, 162 78" />
				<path class="svg-brow left" d="M22 20 C34 14, 54 14, 66 21" />
				<path class="svg-brow right" d="M118 21 C130 14, 151 14, 163 20" />
				<ellipse class="svg-cheek left" cx="22" cy="68" rx="10" ry="7" />
				<ellipse class="svg-cheek right" cx="162" cy="68" rx="10" ry="7" />
				<path class="svg-sweat" d="M166 32 C173 42, 172 50, 165 53 C158 48, 158 40, 166 32Z" />
				<path class="svg-tear" d="M157 69 C164 79, 163 87, 156 90 C149 85, 150 77, 157 69Z" />
				<g class="svg-stars"><path class="svg-star" d="M23 13 L26 20 L33 21 L28 26 L29 33 L23 29 L17 33 L18 26 L13 21 L20 20Z" /><path class="svg-star" d="M159 10 L162 17 L169 18 L164 23 L165 30 L159 26 L153 30 L154 23 L149 18 L156 17Z" /><path class="svg-star" d="M94 5 L96 11 L102 12 L98 16 L99 22 L94 19 L89 22 L90 16 L86 12 L92 11Z" /></g>
				<path class="svg-spiral left" d="M33 56 C33 48, 47 47, 48 56 C49 66, 36 67, 36 58 C36 53, 43 53, 43 58" />
				<path class="svg-spiral right" d="M131 56 C131 48, 145 47, 146 56 C147 66, 134 67, 134 58 C134 53, 141 53, 141 58" />
				<g class="svg-eye left"><circle class="svg-pupil" cx="43" cy="57" r="11.4" /><circle class="svg-pupil-shine" cx="38.8" cy="52.8" r="2.7" /></g>
				<g class="svg-eye right"><circle class="svg-pupil" cx="141" cy="57" r="11.4" /><circle class="svg-pupil-shine" cx="136.8" cy="52.8" r="2.7" /></g>
				<path class="svg-pupil-heart left" d="M43 52 C43 46, 35 43, 32 50 C29 57, 43 66, 43 66 C43 66, 57 57, 54 50 C51 43, 43 46, 43 52Z" />
				<path class="svg-pupil-heart right" d="M141 52 C141 46, 133 43, 130 50 C127 57, 141 66, 141 66 C141 66, 155 57, 152 50 C149 43, 141 46, 141 52Z" />
				<g class="svg-thought-bubble"><circle cx="14" cy="30" r="2.5" /><circle cx="9" cy="22" r="4" /><circle cx="5" cy="13" r="6" /></g>
				<ellipse class="svg-mouth-pad" cx="92" cy="96" rx="23" ry="15" />
				<path class="svg-mouth smile" d="M76 93 C83 105, 101 105, 108 93" />
				<path class="svg-mouth ajar" d="M78 94 C84 102, 100 102, 106 94 C101 99, 84 99, 78 94Z" />
				<path class="svg-mouth open" d="M77 93 C77 80, 86 73, 93 73 C102 73, 111 81, 110 94 C109 108, 99 115, 91 115 C83 115, 77 107, 77 93Z" />
				<path class="svg-mouth-core" d="M83 95 C83 85, 88 80, 93 80 C100 80, 105 86, 104 96 C103 106, 96 110, 91 110 C85 110, 83 104, 83 95Z" />
				<ellipse class="svg-mouth-shine" cx="88" cy="88" rx="3" ry="2.2" />
				<path class="svg-mouth flat" d="M81 96 C87 98, 98 98, 103 96" />
				<path class="svg-mouth grimace" d="M80 91 C87 89, 98 89, 105 91 L104 101 C97 104, 86 104, 80 101Z" />
				<path class="svg-mouth teeth" d="M80 92 L106 92 M84 92 L84 101 M90 92 L90 102 M96 92 L96 102 M102 92 L102 101" />
				<ellipse class="svg-mouth ooh" cx="92" cy="95" rx="8" ry="10" />
				<path class="svg-mouth tremble" d="M78 96 C82 91, 86 101, 90 96 C94 91, 98 101, 104 95" />
				<path class="svg-mouth smirk" d="M80 97 C84 103, 96 104, 106 95" />
				<path class="svg-mouth silly-open" d="M78 92 C78 80, 86 73, 93 73 C102 73, 110 81, 110 92" />
				<ellipse class="svg-mouth silly-tongue" cx="92" cy="100" rx="9" ry="7" />
				<path class="svg-mouth zip" d="M80 96 L106 96 M84 93 L88 99 M88 93 L92 99 M92 93 L96 99 M96 93 L100 99 M100 93 L104 99" />
				<path class="svg-spark" d="M117 84 L124 78 M119 92 L128 93 M112 91 L106 96" />
			</g>
		</svg>`;
}

/** Keeps the old preparation hook for the classed original SVG. */
function prepareMascotSvg(mascot: HTMLButtonElement): void {
	const svg = mascot.querySelector('.binocle__svg');
	if (!(svg instanceof SVGSVGElement)) {
		return;
	}
	svg.setAttribute('focusable', 'false');
}

/** Reports whether expressive particle animations should be skipped. */
function mascotMotionPaused(): boolean {
	return document.documentElement.classList.contains('motion-paused');
}

/** Removes temporary mascot particle elements and clears their timers. */
function stopMascotEffects(mascot: HTMLButtonElement): void {
	globalThis.clearInterval(mascotState.heartTimer);
	globalThis.clearInterval(mascotState.zTimer);
	globalThis.clearInterval(mascotState.laughTimer);
	mascotState.heartTimer = undefined;
	mascotState.zTimer = undefined;
	mascotState.laughTimer = undefined;
	mascot.querySelectorAll('.binocle__heart, .binocle__z, .binocle__laugh, .binocle__laugh-tear, .binocle__ping').forEach((particle) => particle.remove());
}

/** Adds one floating heart around the mascot. */
function createHeart(mascot: HTMLButtonElement): void {
	const heart = document.createElement('span');
	heart.className = 'binocle__heart';
	heart.textContent = ['♥', '♡', '✦'][randomIndex(3)] ?? '♥';
	heart.style.left = `${randomBetween(34, 34)}%`;
	heart.style.setProperty('--heart-x', `${randomBetween(-28, 56)}px`);
	mascot.append(heart);
	heart.addEventListener('animationend', () => heart.remove(), { once: true });
}

/** Adds one sleeping Z particle around the mascot. */
function createSleepZ(mascot: HTMLButtonElement): void {
	const zed = document.createElement('span');
	zed.className = 'binocle__z';
	zed.textContent = 'Z';
	zed.style.left = `${randomBetween(54, 24)}%`;
	zed.style.setProperty('--z-x', `${randomBetween(-14, 42)}px`);
	mascot.append(zed);
	zed.addEventListener('animationend', () => zed.remove(), { once: true });
}

/** Adds one silent laugh-tear particle around the mascot. */
function createLaughParticle(mascot: HTMLButtonElement): void {
	const laugh = document.createElement('span');
	laugh.className = 'binocle__laugh-tear';
	laugh.style.left = `${randomBetween(30, 44)}%`;
	laugh.style.top = `${randomBetween(18, 32)}%`;
	laugh.style.setProperty('--laugh-x', `${randomBetween(-30, 60)}px`);
	laugh.style.setProperty('--laugh-rot', `${randomBetween(-17, 34)}deg`);
	mascot.append(laugh);
	laugh.addEventListener('animationend', () => laugh.remove(), { once: true });
}

/** Adds a click/focus ping around the right lens. */
function createPing(mascot: HTMLButtonElement): void {
	const ping = document.createElement('span');
	ping.className = 'binocle__ping';
	ping.style.left = `${randomBetween(48, 32)}%`;
	ping.style.top = `${randomBetween(30, 30)}%`;
	mascot.append(ping);
	ping.addEventListener('animationend', () => ping.remove(), { once: true });
}

/** Replays the original head-star pop without creating text. */
function startMascotStars(mascot: HTMLButtonElement): void {
	if (mascotMotionPaused()) {
		return;
	}
	mascot.classList.remove('is-star-pop');
	mascot.getBoundingClientRect();
	mascot.classList.add('is-star-pop');
	globalThis.setTimeout(() => mascot.classList.remove('is-star-pop'), 1100);
	mascot.querySelectorAll('.svg-star').forEach((star, index) => {
		star.animate([
			{ opacity: 0, transform: 'translateY(4px) scale(0.25) rotate(-20deg)' },
			{ opacity: 1, transform: 'translateY(-7px) scale(1.35) rotate(12deg)' },
			{ opacity: 1, transform: 'translateY(0) scale(1) rotate(0deg)' },
		], { duration: 560, delay: index * 75, easing: 'cubic-bezier(0.34, 1.56, 0.64, 1)' });
	});
}

/** Pops mascot brows without changing the current mood. */
function liftMascotBrows(mascot: HTMLButtonElement, duration = 680): void {
	mascot.classList.remove('is-brow-pop');
	mascot.getBoundingClientRect();
	mascot.classList.add('is-brow-pop');
	globalThis.setTimeout(() => mascot.classList.remove('is-brow-pop'), duration);
}

/** Starts the particle effect that belongs to a mood. */
function startMascotMoodEffect(mascot: HTMLButtonElement, mood: MascotMood): void {
	if (mascotMotionPaused()) {
		return;
	}
	if (mood === 'love') {
		createHeart(mascot);
		mascotState.heartTimer = globalThis.setInterval(() => createHeart(mascot), 380);
	}
	if (mood === 'excited' || mood === 'happy') {
		startMascotStars(mascot);
	}
	if (mood === 'sleeping') {
		createSleepZ(mascot);
		mascotState.zTimer = globalThis.setInterval(() => createSleepZ(mascot), 720);
	}
	if (mood === 'laughing') {
		createLaughParticle(mascot);
		createLaughParticle(mascot);
		mascotState.laughTimer = globalThis.setInterval(() => createLaughParticle(mascot), 170);
	}
	if (mood === 'surprised' || mood === 'seller') {
		createPing(mascot);
	}
}

/** Restores an awake pose immediately after sleep. */
function wakeMascotPose(mascot: HTMLButtonElement): void {
	mascot.style.setProperty('--blink', '1');
	mascot.style.setProperty('--tilt', '0deg');
	mascotState.targetHeadX = 0;
	mascotState.targetHeadY = 0;
	mascotState.headX *= 0.35;
	mascotState.headY *= 0.35;
}

/** Applies the calm sleeping head tilt immediately. */
function sleepMascotPose(mascot: HTMLButtonElement): void {
	mascot.style.setProperty('--blink', '0.08');
	mascot.style.setProperty('--tilt', '9deg');
	mascotState.targetX = 0;
	mascotState.targetY = 0;
	mascotState.eyeX = 0;
	mascotState.eyeY = 0;
	mascotState.targetHeadX = -7;
	mascotState.targetHeadY = 13;
	mascotState.headX = -7;
	mascotState.headY = 13;
	mascotState.depthX = 7;
	mascotState.depthY = 2;
}

/** Applies a temporary mascot mood that can be overridden after its lock expires. */
function setMascotMood(mascot: HTMLButtonElement, mood: MascotMood, duration = 0, locked = false): void {
	if (mascot.dataset.mood === mood && duration === 0 && !locked) {
		return;
	}
	const previousMood = mascot.dataset.mood;
	globalThis.clearTimeout(mascotState.moodTimer);
	stopMascotEffects(mascot);
	mascot.dataset.mood = mood;
	if (previousMood === 'sleeping' && mood !== 'sleeping') {
		wakeMascotPose(mascot);
	}
	if (mood === 'sleeping') {
		sleepMascotPose(mascot);
	}
	startMascotMoodEffect(mascot, mood);
	if (mood === 'seller') {
		liftMascotBrows(mascot, 520);
	}
	if (locked) {
		mascotState.lockedUntil = Date.now() + duration;
	}
	if (duration > 0) {
		mascotState.moodTimer = globalThis.setTimeout(() => setMascotMood(mascot, 'curious'), duration);
	}
}

/** Detects circular pointer motion and turns it into curious brow movement. */
function updateMascotOrbit(mascot: HTMLButtonElement, angle: number, distance: number): void {
	if (mascotState.lastPointerAngle === undefined || distance <= 68 || distance >= 360) {
		mascotState.orbitTravel *= 0.82;
		mascotState.lastPointerAngle = angle;
		return;
	}
	let delta = angle - mascotState.lastPointerAngle;
	if (delta > Math.PI) {
		delta -= Math.PI * 2;
	} else if (delta < -Math.PI) {
		delta += Math.PI * 2;
	}
	mascotState.orbitTravel = Math.min(Math.PI * 3, mascotState.orbitTravel * 0.92 + Math.abs(delta));
	if (mascotState.orbitTravel > Math.PI * 1.35 && Date.now() - mascotState.lastBrowLift > 680 && Date.now() > mascotState.lockedUntil) {
		setMascotMood(mascot, 'curious', 760, true);
		liftMascotBrows(mascot, 760);
		mascotState.lastBrowLift = Date.now();
		mascotState.orbitTravel = 0;
	}
	mascotState.lastPointerAngle = angle;
}

/** Applies the pointer-derived mascot pose variables. */
function updateMascotPoseFromPointer(mascot: HTMLButtonElement, dx: number, dy: number, closeness: number): void {
	mascotState.targetX = clamp(dx / 36, -7, 7);
	mascotState.targetY = clamp(dy / 42, -4.8, 4.8);
	mascotState.targetHeadX = clamp(dx / 84, -6, 6);
	mascotState.targetHeadY = clamp(-dy / 86, -6, 6);
	mascotState.lastMove = Date.now();
	mascotState.idleMoodShown = false;
	mascot.style.setProperty('--tilt', `${clamp(dx / 140, -3, 3).toFixed(2)}deg`);
	mascot.style.setProperty('--body-roll', `${clamp(dx / 190, -2.2, 2.2).toFixed(2)}deg`);
	mascot.style.setProperty('--body-x', `${clamp(dx / 120, -3.5, 3.5).toFixed(2)}px`);
	mascot.style.setProperty('--body-y', `${clamp(dy / 135, -2.5, 3.5).toFixed(2)}px`);
	mascotState.depthX = 5 - clamp(dx / 85, -4, 4);
	mascotState.depthY = 4 - clamp(dy / 95, -3, 4);
	mascot.style.setProperty('--depth-z', `${(closeness * 16).toFixed(2)}px`);
}

/** Converts the pointer position into gaze, subtle head orientation and mood. */
function updateMascotTarget(mascot: HTMLButtonElement, pointerX: number, pointerY: number): void {
	if (document.body.classList.contains('portal-open')) {
		return;
	}
	const wasSleeping = mascot.dataset.mood === 'sleeping';
	const rect = mascot.getBoundingClientRect();
	const centerX = rect.left + rect.width / 2;
	const centerY = rect.top + rect.height / 2;
	const dx = pointerX - centerX;
	const dy = pointerY - centerY;
	const distance = Math.hypot(dx, dy);
	const closeness = clamp(1 - distance / 520, 0, 1);
	const angle = Math.atan2(dy, dx);
	updateMascotOrbit(mascot, angle, distance);
	updateMascotPoseFromPointer(mascot, dx, dy, closeness);
	if (wasSleeping && Date.now() > mascotState.lockedUntil) {
		setMascotMood(mascot, distance < 180 ? 'gentle' : 'curious', 520, true);
		return;
	}
	if (Date.now() < mascotState.lockedUntil) {
		return;
	}
	if (distance < 92) {
		setMascotMood(mascot, 'close');
	} else if (distance < 170) {
		setMascotMood(mascot, 'gentle');
	} else if (distance < 280) {
		setMascotMood(mascot, 'happy');
	} else if (mascot.dataset.mood !== 'bye') {
		setMascotMood(mascot, 'curious');
	}
}

/** Smooths mascot eye tracking and handles idle personality states. */
function animateMascot(mascot: HTMLButtonElement): void {
	const mood = mascot.dataset.mood;
	const sleeping = mood === 'sleeping';
	if (mood === 'thinking') {
		mascotState.targetX += (-4.4 - mascotState.targetX) * 0.02;
		mascotState.targetY += (-2.8 - mascotState.targetY) * 0.02;
		mascotState.targetHeadX += (-2.2 - mascotState.targetHeadX) * 0.018;
		mascotState.targetHeadY += (1.1 - mascotState.targetHeadY) * 0.018;
	} else if (mood === 'shy') {
		mascotState.targetX += (3.8 - mascotState.targetX) * 0.045;
		mascotState.targetY += (3.1 - mascotState.targetY) * 0.045;
		mascotState.targetHeadX += (1.6 - mascotState.targetHeadX) * 0.03;
		mascotState.targetHeadY += (-0.8 - mascotState.targetHeadY) * 0.03;
	} else if (sleeping) {
		mascotState.targetX += (0 - mascotState.targetX) * 0.08;
		mascotState.targetY += (0 - mascotState.targetY) * 0.08;
		mascotState.targetHeadX += (-7 - mascotState.targetHeadX) * 0.06;
		mascotState.targetHeadY += (13 - mascotState.targetHeadY) * 0.06;
		mascotState.depthX += (7 - mascotState.depthX) * 0.04;
		mascotState.depthY += (2 - mascotState.depthY) * 0.04;
	}
	const speed = sleeping ? 0.09 : 0.16;
	const headSpeed = sleeping ? 0.055 : 0.11;
	mascotState.eyeX += (mascotState.targetX - mascotState.eyeX) * speed;
	mascotState.eyeY += (mascotState.targetY - mascotState.eyeY) * speed;
	mascotState.headX += (mascotState.targetHeadX - mascotState.headX) * headSpeed;
	mascotState.headY += (mascotState.targetHeadY - mascotState.headY) * headSpeed;
	mascot.style.setProperty('--look-x', `${mascotState.eyeX.toFixed(1)}px`);
	mascot.style.setProperty('--look-y', `${mascotState.eyeY.toFixed(1)}px`);
	mascot.style.setProperty('--lean-x', `${mascotState.headX.toFixed(1)}deg`);
	mascot.style.setProperty('--lean-y', `${mascotState.headY.toFixed(1)}deg`);
	mascot.style.setProperty('--parallax-x', `${(mascotState.headX * 0.16).toFixed(1)}px`);
	mascot.style.setProperty('--parallax-y', `${(mascotState.headY * -0.12).toFixed(1)}px`);
	mascot.style.setProperty('--depth-x', `${mascotState.depthX.toFixed(1)}px`);
	mascot.style.setProperty('--depth-y', `${mascotState.depthY.toFixed(1)}px`);
	const idle = Date.now() - mascotState.lastMove;
	if (idle > 3600 && !sleeping && !document.body.classList.contains('portal-open')) {
		mascotState.targetX = Math.sin(Date.now() / 1200) * 2.2;
		mascotState.targetY = Math.cos(Date.now() / 1450) * 1.4;
		mascotState.targetHeadX = Math.sin(Date.now() / 1800) * 0.9;
		mascotState.targetHeadY = Math.cos(Date.now() / 2100) * 0.55;
		mascot.style.setProperty('--tilt', '0deg');
		mascot.style.setProperty('--body-roll', '0deg');
		mascot.style.setProperty('--body-x', '0px');
		mascot.style.setProperty('--body-y', '0px');
		mascotState.depthX += (5 - mascotState.depthX) * 0.08;
		mascotState.depthY += (4 - mascotState.depthY) * 0.08;
		mascot.style.setProperty('--depth-z', '0px');
	}
	if (idle > 75000 && !sleeping && Date.now() > mascotState.lockedUntil) {
		setMascotMood(mascot, 'sleeping');
	} else if (idle > 14000 && !mascotState.idleMoodShown && Date.now() > mascotState.lockedUntil) {
		mascotState.idleMoodShown = true;
		const idleMoods: MascotMood[] = ['thinking', 'shy', 'proud'];
		setMascotMood(mascot, idleMoods[randomIndex(idleMoods.length)] ?? 'thinking', 2200, true);
		liftMascotBrows(mascot);
	}
	mascotState.frame = requestAnimationFrame(() => animateMascot(mascot));
}

/** Starts the blink loop for the classed original SVG eye groups. */
function startMascotBlink(mascot: HTMLButtonElement): void {
	const blink = (): void => {
		const sleeping = mascot.dataset.mood === 'sleeping';
		mascot.style.setProperty('--blink', '0.08');
		if (!sleeping) {
			globalThis.setTimeout(() => mascot.style.setProperty('--blink', '1'), 110);
		}
		globalThis.setTimeout(blink, sleeping ? randomBetween(1800, 2400) : randomBetween(2600, 3200));
	};
	blink();
}

/** Wires pointer, focus and click interactions to the restored mascot. */
function bindMascotInteractions(mascot: HTMLButtonElement): void {
	prepareMascotSvg(mascot);
	let lastScrollMascotUpdate = 0;
	globalThis.addEventListener('pointermove', (event) => updateMascotTarget(mascot, event.clientX, event.clientY), { passive: true });
	mascot.addEventListener('pointerenter', () => setMascotMood(mascot, 'happy', 700));
	mascot.addEventListener('focus', () => setMascotMood(mascot, 'listening', 700));
	mascot.addEventListener('pointerdown', () => {
		setMascotMood(mascot, 'excited', 900, true);
		createPing(mascot);
	});
	mascot.addEventListener('dblclick', () => setMascotMood(mascot, 'love', 1800, true));
	globalThis.addEventListener('scroll', () => {
		const now = Date.now();
		if (now - lastScrollMascotUpdate < 900 || now < mascotState.lockedUntil || document.body.classList.contains('portal-open')) {
			return;
		}
		lastScrollMascotUpdate = now;
		setMascotMood(mascot, 'curious', 700, true);
		liftMascotBrows(mascot, 520);
	}, { passive: true });
	globalThis.addEventListener('blur', () => setMascotMood(mascot, 'bye', 1000, true));
	startMascotBlink(mascot);
	if (mascotState.frame !== undefined) {
		cancelAnimationFrame(mascotState.frame);
	}
	animateMascot(mascot);
}

/** Builds the mascot button markup from the extracted original drawing. */
function characterMarkup(): string {
	return `
		<button class="binocle" type="button" data-mood="curious" aria-label="Open Prismatica portal">
			${mascotSvgMarkup()}
			<span class="right-lens-hotspot" aria-hidden="true"></span>
		</button>`;
}

/** Places the mascot into its header anchor. */
function mountMascot(): void {
	const anchor = queryElement('#mascot-anchor', isHtmlElement);
	if (!anchor) {
		return;
	}
	setTrustedInnerHTML(anchor, characterMarkup());
	const mascot = queryElement('.binocle', isButton);
	if (mascot) {
		bindMascotInteractions(mascot);
		mascot.addEventListener('click', () => openPortal('start'));
	}
}

/** Creates the portal document fragment. */
function createPortalMarkup(mode: PortalMode): string {
	const quick = mode === 'connect';
	const requiresEmailVerification = authConfig.requireEmailVerification;
	const registerNote = requiresEmailVerification
		? 'Create an account with email verification before opening your workspace.'
		: 'Create a local development account and open your workspace.';
	return `
		<dialog id="portal" class="portal portal--${quick ? 'quick' : 'start'}" aria-labelledby="portal-title">
			<h2 id="portal-title" class="visually-hidden">Prismatica workspace portal</h2>
			<button class="portal__close" type="button" aria-label="Close portal" data-close-portal>×</button>
			<section class="portal__panel portal__panel--login" aria-label="Secure connection panel">
				<div class="portal-login-area">
					<div class="portal-brand portal-brand--auth" aria-hidden="true"><span class="portal-brand__mark">P</span><span>Prismatica</span></div>
					<p class="portal-kicker">${quick ? 'Account connection' : 'Secure account'}</p>
					<h2 aria-hidden="true" data-auth-title>${quick ? 'Open your workspace' : 'Create your workspace'}</h2>
					<p class="portal-note" data-auth-note>${quick ? 'Sign in to connect Prismatica with the osionos app.' : registerNote}</p>
					<div class="portal-auth-switch" role="group" aria-label="Authentication mode">
						<button class="portal-auth-switch__button" type="button" data-auth-switch="register" aria-pressed="${quick ? 'false' : 'true'}">Create account</button>
						<button class="portal-auth-switch__button" type="button" data-auth-switch="login" aria-pressed="${quick ? 'true' : 'false'}">Sign in</button>
					</div>
					<form class="portal-login" novalidate>
						<div class="field-row portal-register-identity">
							<div class="field field--half portal-register-only">
								<label for="portal-username">Username <span aria-hidden="true">*</span></label>
								<input id="portal-username" name="username" type="text" autocomplete="username" placeholder="prism-user" minlength="3" maxlength="32" required />
								<p id="portal-username-inline-error" class="field-validation-message" data-validation-state="idle" aria-live="polite">Choose a unique username.</p>
							</div>
							<div class="field field--half">
								<label for="portal-email">Email <span aria-hidden="true">*</span></label>
								<input id="portal-email" name="email" type="email" autocomplete="email" inputmode="email" placeholder="you@example.com" required />
								<p id="portal-email-inline-error" class="field-validation-message" data-validation-state="idle" aria-live="polite">We verify the email format before sending it.</p>
							</div>
						</div>
						<div class="field" data-password-field>
							<label for="portal-password">Password <span aria-hidden="true">*</span></label>
							<div class="password-control">
								<input id="portal-password" name="password" type="password" autocomplete="current-password" placeholder="8+ chars, A–z, 0–9, symbol" required />
								<button class="password-control__toggle" type="button" data-password-toggle aria-label="Show password" aria-controls="portal-password" aria-pressed="false" title="Show password"><span aria-hidden="true">◉</span></button>
							</div>
							<p class="portal-password-hint portal-register-only">Minimum 8 characters with uppercase, lowercase, number and symbol.</p>
							<div class="password-strength portal-register-only" data-password-strength data-strength-level="empty" aria-live="polite">
								<div class="password-strength__meter" aria-hidden="true">
									<span class="password-strength__segment" data-password-segment></span>
									<span class="password-strength__segment" data-password-segment></span>
									<span class="password-strength__segment" data-password-segment></span>
									<span class="password-strength__segment" data-password-segment></span>
								</div>
								<span class="password-strength__label" data-password-strength-label>Enter a password</span>
								<ul class="password-strength__rules" data-password-rules></ul>
							</div>
							<button class="portal-link portal-link--button portal-login-only" type="button" data-forgot-password>Forgot your password?</button>
						</div>
						<div class="field portal-register-only">
							<label for="portal-password-confirm">Repeat password <span aria-hidden="true">*</span></label>
							<div class="password-control">
								<input id="portal-password-confirm" name="password_confirm" type="password" autocomplete="new-password" placeholder="Repeat your password" required />
								<button class="password-control__toggle" type="button" data-password-toggle aria-label="Show repeated password" aria-controls="portal-password-confirm" aria-pressed="false" title="Show repeated password"><span aria-hidden="true">◉</span></button>
							</div>
							<p id="portal-password-match" class="password-match" data-password-match aria-live="polite">Repeat the same password.</p>
						</div>
						<label class="consent-toggle portal-consent" for="portal-terms-consent">
							<input id="portal-terms-consent" name="terms_consent" type="checkbox" required />
							<span>I have read and accept the <a href="/legal/terms/" target="_blank" rel="noreferrer">Terms of Service</a> and <a href="/legal/privacy-policy/" target="_blank" rel="noreferrer">Privacy Policy</a>.</span>
						</label>
						<label class="consent-toggle portal-consent" for="portal-email-verification-consent">
							<input id="portal-email-verification-consent" name="email_verification_consent" type="checkbox" ${requiresEmailVerification ? 'checked required' : ''} />
							<span>${requiresEmailVerification ? 'Send the email verification link required to activate this account.' : 'Development option: send a verification email instead of auto-confirming this local account.'}</span>
						</label>
						<label class="consent-toggle portal-consent" for="portal-newsletter-consent">
							<input id="portal-newsletter-consent" name="newsletter_consent" type="checkbox" />
							<span>I agree to receive the Prismatica newsletter. This is optional and has no effect on account access.</span>
						</label>
						<p class="portal-verification-note portal-register-only">Security and workspace notifications are enabled automatically. You can change preferences later in your workspace.</p>
						<div class="turnstile-box" data-turnstile-widget aria-label="Anti-abuse verification"></div>
						<input type="hidden" name="turnstile_token" data-turnstile-token />
						<button class="portal-cta" type="submit" data-login-submit>${quick ? 'Sign in securely →' : 'Create protected account →'}</button>
						<div class="portal-recovery-actions" data-recovery-actions hidden>
							<button class="portal-cta" type="submit" data-recovery-submit>Send reset link</button>
							<button class="portal-secondary" type="button" data-cancel-recovery>Back to login</button>
						</div>
						<button class="portal-secondary" type="button" data-close-portal>Return to the tour</button>
						<output id="portal-error-msg" class="portal-error" role="status" aria-live="polite" aria-atomic="true"></output>
					</form>
				</div>
			</section>
			<section class="portal__panel portal__panel--preview" aria-label="Connection summary">
				<div class="portal-demo-area">
					<p class="portal-kicker portal-kicker--future">Connection summary</p>
					<h3>One account, two workspaces.</h3>
					<p class="portal-summary">Your Prismatica identity opens a dedicated osionos workspace through the secure bridge.</p>
					<div class="portal-cards" aria-label="Security assurances">
						<article class="portal-card"><span>01</span><h3>HTTPS gateway</h3><p>Browser requests stay behind the website gateway.</p></article>
						<article class="portal-card"><span>02</span><h3>Verified identity</h3><p>${requiresEmailVerification ? 'New accounts activate after email confirmation.' : 'Local accounts can auto-confirm in development.'}</p></article>
						<article class="portal-card"><span>03</span><h3>App access</h3><p>osionos receives a signed session, not database credentials.</p></article>
					</div>
				</div>
			</section>
		</dialog>`;
}

// Native <dialog>.showModal() handles focus trap and ESC for us; the manual
// trapFocus and focusableElements helpers that lived here were removed in Step A.

type PortalFormElements = {
	error: HTMLOutputElement;
	email: HTMLInputElement;
	password: HTMLInputElement;
	confirmPassword: HTMLInputElement | null;
	username: HTMLInputElement | null;
	emailVerificationConsent: HTMLInputElement | null;
	termsConsent: HTMLInputElement | null;
	newsletterConsent: HTMLInputElement | null;
	submitButton: HTMLButtonElement | null;
};

/** Returns the typed portal form controls needed by submit handlers. */
function portalFormElements(portal: HTMLElement): PortalFormElements | null {
	const error = portal.querySelector('.portal-error');
	const email = portal.querySelector('#portal-email');
	const password = portal.querySelector('#portal-password');
	const confirmPassword = portal.querySelector('#portal-password-confirm');
	const username = portal.querySelector('#portal-username');
	const emailVerificationConsent = portal.querySelector('#portal-email-verification-consent');
	const termsConsent = portal.querySelector('#portal-terms-consent');
	const newsletterConsent = portal.querySelector('#portal-newsletter-consent');
	const submitButton = portal.querySelector('[data-login-submit]');
	if (!(error instanceof HTMLOutputElement) || !(email instanceof HTMLInputElement) || !(password instanceof HTMLInputElement)) {
		return null;
	}
	return {
		error,
		email,
		password,
		confirmPassword: confirmPassword instanceof HTMLInputElement ? confirmPassword : null,
		username: username instanceof HTMLInputElement ? username : null,
		emailVerificationConsent: emailVerificationConsent instanceof HTMLInputElement ? emailVerificationConsent : null,
		termsConsent: termsConsent instanceof HTMLInputElement ? termsConsent : null,
		newsletterConsent: newsletterConsent instanceof HTMLInputElement ? newsletterConsent : null,
		submitButton: submitButton instanceof HTMLButtonElement ? submitButton : null,
	};
}

/** Clears invalid state from portal controls. */
function clearPortalFieldErrors(...fields: HTMLInputElement[]): void {
	fields.forEach((field) => {
		field.removeAttribute('aria-invalid');
		field.removeAttribute('aria-describedby');
	});
}

/** Marks a portal input as invalid and focuses it. */
function showPortalFieldError(error: HTMLOutputElement, field: HTMLInputElement, message: string): void {
	error.textContent = message;
	field.setAttribute('aria-invalid', 'true');
	field.setAttribute('aria-describedby', 'portal-error-msg');
	field.focus();
}

/** Builds the schema-aligned registration profile payload. */
function portalRegistrationProfile(elements: PortalFormElements): RegisterProfile {
	return {
		username: elements.username?.value.trim() ?? '',
		confirmPassword: elements.confirmPassword?.value ?? '',
		emailVerificationConsent: authConfig.requireEmailVerification ? (elements.emailVerificationConsent?.checked ?? true) : Boolean(elements.emailVerificationConsent?.checked),
		newsletterConsent: Boolean(elements.newsletterConsent?.checked),
		notificationsEnabled: true,
	};
}

/** Clears invalid states across the dynamic portal auth controls. */
function clearPortalAuthErrors(elements: PortalFormElements): void {
	const optionalFields = [elements.confirmPassword, elements.username, elements.emailVerificationConsent].filter((field): field is HTMLInputElement => field instanceof HTMLInputElement);
	clearPortalFieldErrors(elements.email, elements.password, ...optionalFields);
}

/** Validates registration-only identity fields. */
function validateRegistrationIdentity(elements: PortalFormElements, isRegister: boolean): boolean {
	const { email, error, username } = elements;
	const usernamePattern = /^\w[\w.-]{2,31}$/;
	if (isRegister && username && !usernamePattern.test(username.value.trim())) {
		showPortalFieldError(error, username, 'Error: Choose a username with 3–32 letters, numbers, dots, underscores, or hyphens.');
		return false;
	}
	if (!validateEmailField(email, 'Please enter your email address')) {
		showPortalFieldError(error, email, 'Please enter a valid email address (e.g. you@example.com)');
		return false;
	}
	return true;
}

/** Validates login and registration password fields. */
function validatePortalPasswordFields(elements: PortalFormElements, isRegister: boolean): boolean {
	const { confirmPassword, error, password } = elements;
	if (isRegister && (!validatePassword(password.value) || !checkPasswordStrength(password.value).passed)) {
		showPortalFieldError(error, password, 'Error: Your password does not meet the security requirements.');
		notifyWithMascot({
			kind: 'warning',
			title: 'Password too weak',
			message: 'Your password does not meet the security requirements.',
			duration: 5000,
		});
		return false;
	}
	if (isRegister && confirmPassword && password.value !== confirmPassword.value) {
		showPortalFieldError(error, confirmPassword, 'Error: Repeat the same password.');
		notifyWithMascot({
			kind: 'warning',
			title: 'Passwords do not match',
			message: 'Make sure both fields are identical.',
			duration: 5000,
		});
		return false;
	}
	if (!isRegister && password.value.length === 0) {
		showPortalFieldError(error, password, 'Error: Enter your password.');
		return false;
	}
	return true;
}

/** Validates profile-only fields that mirror optional users schema columns. */
function validatePortalProfileFields(elements: PortalFormElements, isRegister: boolean): boolean {
	const { emailVerificationConsent, error, termsConsent } = elements;
	if (isRegister && termsConsent && !termsConsent.checked) {
		showPortalFieldError(error, termsConsent, 'Error: Accept the Terms of Service and Privacy Policy to create an account.');
		return false;
	}
	if (authConfig.requireEmailVerification && isRegister && emailVerificationConsent && !emailVerificationConsent.checked) {
		showPortalFieldError(error, emailVerificationConsent, 'Error: Email verification must stay enabled for account security.');
		return false;
	}
	return true;
}

/** Applies a temporary mood to the mounted mascot when it exists. */
function setMountedMascotMood(mood: MascotMood, duration: number): void {
	const mascot = queryElement('.binocle', isButton);
	if (mascot) {
		setMascotMood(mascot, mood, duration, true);
	}
}

/** Shows a global notification and mirrors it through the mascot when present. */
function notifyWithMascot(options: NotificationOptions, mascot: HTMLButtonElement | null = queryElement('.binocle', isButton)): void {
	notify(options);
	if (!mascot) {
		return;
	}
	const moodMap: Record<NotificationKind, MascotMood> = {
		success: 'happy',
		error: 'scared',
		warning: 'surprised',
		info: 'curious',
	};
	setMascotMood(mascot, moodMap[options.kind], 2000, true);
}

/** Returns a readable API error without exposing raw JSON or status details. */
function humanAuthMessage(message: string): string {
	const trimmed = message.trim();
	if (!trimmed) {
		return 'Please check the form and try again.';
	}
	if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
		try {
			const payload = JSON.parse(trimmed) as Record<string, unknown>;
			const candidate = [payload.error_description, payload.msg, payload.message, payload.error].find((value) => typeof value === 'string' && value.trim().length > 0);
			return typeof candidate === 'string' ? candidate : 'Please check the form and try again.';
		} catch {
			return 'Please check the form and try again.';
		}
	}
	return trimmed.replace(/^error:\s*/i, '').slice(0, 220);
}

function messageMentions(message: string, ...needles: string[]): boolean {
	const normalized = message.toLowerCase();
	return needles.some((needle) => normalized.includes(needle.toLowerCase()));
}

/** Validates email beyond native type=email checks for common mistakes. */
type FieldValidationState = 'idle' | 'error' | 'warning' | 'success';

type EmailValidationResult = {
	valid: boolean;
	state: FieldValidationState;
	message: string;
};

function editDistance(left: string, right: string): number {
	const previous = Array.from({ length: right.length + 1 }, (_, index) => index);
	for (let leftIndex = 1; leftIndex <= left.length; leftIndex += 1) {
		const current = [leftIndex];
		for (let rightIndex = 1; rightIndex <= right.length; rightIndex += 1) {
			const substitutionCost = left[leftIndex - 1] === right[rightIndex - 1] ? 0 : 1;
			current[rightIndex] = Math.min(
				(current[rightIndex - 1] ?? 0) + 1,
				(previous[rightIndex] ?? 0) + 1,
				(previous[rightIndex - 1] ?? 0) + substitutionCost,
			);
		}
		previous.splice(0, previous.length, ...current);
	}
	return previous[right.length] ?? Number.POSITIVE_INFINITY;
}

function suggestedEmailDomain(domain: string): string {
	const normalized = domain.toLowerCase();
	if (EMAIL_DOMAIN_ALIASES[normalized]) {
		return EMAIL_DOMAIN_ALIASES[normalized];
	}
	const closeMatch = COMMON_EMAIL_DOMAINS.find((candidate) => editDistance(normalized, candidate) === 1);
	return closeMatch ?? '';
}

function emailValidationResult(field: HTMLInputElement): EmailValidationResult {
	const email = field.value.trim();
	if (!email) {
		return { valid: !field.required, state: 'idle', message: field.required ? 'Enter your email address.' : '' };
	}
	if (!field.validity.valid || !validateEmail(email) || email.includes('..')) {
		return { valid: false, state: 'error', message: 'Please enter a valid email address (e.g. you@example.com).' };
	}
	const domain = email.split('@').pop() ?? '';
	const suggestion = suggestedEmailDomain(domain);
	if (suggestion && suggestion !== domain.toLowerCase()) {
		return { valid: true, state: 'warning', message: `Did you mean ${email.slice(0, email.lastIndexOf('@') + 1)}${suggestion}?` };
	}
	return { valid: true, state: 'success', message: 'Email format looks correct.' };
}

function hasValidEmailFormat(field: HTMLInputElement): boolean {
	return emailValidationResult(field).valid && field.value.trim().length > 0;
}

function describedByValues(field: HTMLInputElement): Set<string> {
	return new Set((field.getAttribute('aria-describedby') ?? '').split(/\s+/).filter(Boolean));
}

function ensureInlineFieldMessage(field: HTMLInputElement): HTMLElement {
	const id = `${field.id || field.name || 'field'}-inline-error`;
	let message = document.getElementById(id);
	if (!(message instanceof HTMLElement)) {
		message = document.createElement('p');
		message.id = id;
		message.setAttribute('role', 'alert');
		field.after(message);
	}
	message.className = 'field-validation-message';
	return message;
}

function showInlineFieldMessage(field: HTMLInputElement, message: string, state: FieldValidationState): void {
	const messageElement = ensureInlineFieldMessage(field);
	messageElement.textContent = message;
	messageElement.dataset.validationState = state;
	if (state === 'error') {
		field.setAttribute('aria-invalid', 'true');
	} else {
		field.removeAttribute('aria-invalid');
	}
	const describedBy = describedByValues(field);
	describedBy.add(messageElement.id);
	field.setAttribute('aria-describedby', Array.from(describedBy).join(' '));
}

function showInlineFieldError(field: HTMLInputElement, message: string): void {
	showInlineFieldMessage(field, message, 'error');
}

function clearInlineFieldError(field: HTMLInputElement): void {
	const messageElement = document.getElementById(`${field.id || field.name || 'field'}-inline-error`);
	if (messageElement instanceof HTMLElement) {
		messageElement.textContent = '';
		messageElement.dataset.validationState = 'idle';
	}
	const describedBy = describedByValues(field);
	describedBy.delete(`${field.id || field.name || 'field'}-inline-error`);
	if (describedBy.size > 0) {
		field.setAttribute('aria-describedby', Array.from(describedBy).join(' '));
	} else {
		field.removeAttribute('aria-describedby');
	}
	field.removeAttribute('aria-invalid');
}

function validateEmailField(field: HTMLInputElement, emptyMessage?: string): boolean {
	const result = emailValidationResult(field);
	if (field.value.trim().length === 0) {
		if (emptyMessage) {
			showInlineFieldError(field, emptyMessage);
			return false;
		}
		clearInlineFieldError(field);
		return !field.required;
	}
	if (!result.valid) {
		showInlineFieldError(field, result.message);
		return false;
	}
	showInlineFieldMessage(field, result.message, result.state);
	return true;
}

function updateEmailFieldFeedback(field: HTMLInputElement): void {
	const result = emailValidationResult(field);
	if (result.state === 'idle') {
		clearInlineFieldError(field);
		return;
	}
	showInlineFieldMessage(field, result.message, result.state);
}

function usernameValidationState(field: HTMLInputElement): { valid: boolean; message: string; state: FieldValidationState } {
	const username = field.value.trim();
	if (!username) {
		return { valid: false, message: 'Choose a unique username.', state: 'idle' };
	}
	if (!/^\w[\w.-]{2,31}$/.test(username)) {
		return { valid: false, message: 'Use 3–32 letters, numbers, dots, underscores, or hyphens.', state: 'error' };
	}
	return { valid: true, message: 'Checking username availability…', state: 'warning' };
}

function setPortalAvailabilityState(portal: HTMLElement, field: 'email' | 'username', state: 'unknown' | 'checking' | 'available' | 'taken'): void {
	portal.dataset[`${field}Available`] = state;
}

function showAvailabilityResult(field: HTMLInputElement, result: AvailabilityFieldResult): void {
	if (result.available === false) {
		showInlineFieldMessage(field, result.message, 'error');
		field.setAttribute('aria-invalid', 'true');
		return;
	}
	if (result.available === true) {
		showInlineFieldMessage(field, result.message, 'success');
		field.removeAttribute('aria-invalid');
	}
}

function availabilityStateAllowsSubmit(portal: HTMLElement, field: 'email' | 'username'): boolean {
	const state = portal.dataset[`${field}Available`];
	return state !== 'checking' && state !== 'taken';
}

function bindEmailFieldValidation(scope: ParentNode = document): void {
	queryElements('input[type="email"]', (element): element is HTMLInputElement => element instanceof HTMLInputElement).forEach((field) => {
		if ((scope instanceof Node && !scope.contains(field)) || field.dataset.emailValidationBound === 'true') {
			return;
		}
		field.dataset.emailValidationBound = 'true';
		field.addEventListener('blur', () => validateEmailField(field));
		field.addEventListener('input', () => updateEmailFieldFeedback(field));
	});
}

function renderPasswordStrength(root: HTMLElement, password: string): void {
	const result = checkPasswordStrength(password);
	root.dataset.strengthLevel = result.level;
	root.querySelectorAll('[data-password-segment]').forEach((segment, index) => {
		segment.classList.toggle('is-filled', index < result.score);
	});
	const label = root.querySelector('[data-password-strength-label]');
	if (label instanceof HTMLElement) {
		label.textContent = result.level === 'empty' ? 'Enter a password' : `${result.level[0].toUpperCase()}${result.level.slice(1)} password`;
	}
	const rules = root.querySelector('[data-password-rules]');
	if (rules instanceof HTMLUListElement) {
		rules.replaceChildren(...passwordRuleResults(password).map((rule) => {
			const item = document.createElement('li');
			item.className = `password-strength__rule ${rule.passed ? 'is-met' : 'is-unmet'}`;
			item.textContent = rule.label;
			return item;
		}));
	}
}

function syncPasswordMatchStatus(match: HTMLElement | null, password: HTMLInputElement, confirmPassword: HTMLInputElement): boolean {
	if (!match) {
		return password.value === confirmPassword.value;
	}
	const hasConfirmation = confirmPassword.value.length > 0;
	const matches = hasConfirmation && password.value === confirmPassword.value;
	match.classList.toggle('is-match', matches);
	match.classList.toggle('is-mismatch', hasConfirmation && !matches);
	let message = 'Repeat the same password.';
	if (matches) {
		message = 'Passwords match.';
	} else if (hasConfirmation) {
		message = 'Passwords do not match.';
	}
	match.textContent = message;
	return matches;
}

function syncPortalPasswordFeedback(portal: HTMLElement, elements: PortalFormElements): boolean {
	const strengthRoot = portal.querySelector('[data-password-strength]');
	if (strengthRoot instanceof HTMLElement) {
		renderPasswordStrength(strengthRoot, elements.password.value);
	}
	const match = portal.querySelector('[data-password-match]');
	let matchElement: HTMLElement | null = null;
	if (match instanceof HTMLElement) {
		matchElement = match;
	}
	let passwordsMatch = true;
	if (elements.confirmPassword) {
		passwordsMatch = syncPasswordMatchStatus(matchElement, elements.password, elements.confirmPassword);
	}
	return checkPasswordStrength(elements.password.value).passed && passwordsMatch;
}

function updatePortalSubmitAvailability(portal: HTMLElement, elements: PortalFormElements): void {
	if (!(elements.submitButton instanceof HTMLButtonElement) || elements.submitButton.dataset.busy === 'true' || portal.dataset.portalMode === 'recovery') {
		return;
	}
	if (portal.dataset.authMode !== 'register') {
		elements.submitButton.disabled = !hasValidEmailFormat(elements.email);
		return;
	}
	const passwordReady = syncPortalPasswordFeedback(portal, elements);
	const termsReady = !(elements.termsConsent instanceof HTMLInputElement) || elements.termsConsent.checked;
	const verificationReady = !authConfig.requireEmailVerification || !(elements.emailVerificationConsent instanceof HTMLInputElement) || elements.emailVerificationConsent.checked;
	const usernameReady = !(elements.username instanceof HTMLInputElement) || /^\w[\w.-]{2,31}$/.test(elements.username.value.trim());
	const availabilityReady = availabilityStateAllowsSubmit(portal, 'email') && availabilityStateAllowsSubmit(portal, 'username');
	elements.submitButton.disabled = !(passwordReady && termsReady && verificationReady && usernameReady && hasValidEmailFormat(elements.email) && availabilityReady);
}

/** Handles the password recovery variant of the portal form. */
async function submitPortalRecovery(portal: HTMLElement, elements: PortalFormElements): Promise<void> {
	const { email, error } = elements;
	const turnstileToken = readTurnstileToken(portal);
	clearPortalFieldErrors(email);
	if (!validateEmailField(email, 'Please enter your email address')) {
		showPortalFieldError(error, email, email.value.trim().length === 0 ? 'Please enter your email address' : 'Please enter a valid email address (e.g. you@example.com)');
		return;
	}
	if (!turnstileToken) {
		error.textContent = 'Error: Complete the anti-abuse check.';
		return;
	}
	const recoverySubmit = portal.querySelector('[data-recovery-submit]');
	setMountedMascotMood('listening', 1600);
	if (recoverySubmit instanceof HTMLButtonElement) {
		recoverySubmit.disabled = true;
		recoverySubmit.textContent = 'Sending…';
	}
	try {
		await requestPasswordRecovery(email.value, turnstileToken);
		notifyWithMascot({
			kind: 'success',
			title: 'Reset link sent',
			message: 'If an account exists for that email, a reset link has been sent.',
			duration: 6000,
		});
		announce('If an account exists for that email, a reset link has been sent.');
	} catch {
		notifyWithMascot({
			kind: 'error',
			title: 'Connection failed',
			message: 'Could not reach the server. Check your connection and try again.',
			duration: 8000,
		});
		setMountedMascotMood('scared', 1200);
		announce('Network error — please try again later.');
	} finally {
		if (recoverySubmit instanceof HTMLButtonElement) {
			recoverySubmit.disabled = false;
			recoverySubmit.textContent = 'Send reset link';
		}
	}
}

function validateRegistrationAvailability(portal: HTMLElement, elements: PortalFormElements, isRegister: boolean): boolean {
	if (!isRegister) {
		return true;
	}
	if (portal.dataset.usernameAvailable === 'checking' || portal.dataset.emailAvailable === 'checking') {
		elements.error.textContent = 'Checking username and email availability…';
		return false;
	}
	if (portal.dataset.usernameAvailable === 'taken' && elements.username) {
		showPortalFieldError(elements.error, elements.username, 'Error: This username is already taken.');
		return false;
	}
	if (portal.dataset.emailAvailable === 'taken') {
		showPortalFieldError(elements.error, elements.email, 'Error: This email is already registered.');
		return false;
	}
	return true;
}

/** Validates portal auth input and returns the Turnstile token when valid. */
function validatePortalAuth(portal: HTMLElement, elements: PortalFormElements, isRegister: boolean): string | null {
	const turnstileToken = readTurnstileToken(portal);
	clearPortalAuthErrors(elements);
	if (!validateRegistrationIdentity(elements, isRegister) || !validatePortalPasswordFields(elements, isRegister) || !validatePortalProfileFields(elements, isRegister)) {
		return null;
	}
	if (!validateRegistrationAvailability(portal, elements, isRegister)) {
		return null;
	}
	if (!turnstileToken) {
		elements.error.textContent = 'Error: Complete the anti-abuse check.';
		return null;
	}
	elements.error.textContent = '';
	return turnstileToken;
}

/** Updates the portal submit button busy state. */
function setPortalSubmitBusy(button: HTMLButtonElement | null, busy: boolean, isRegister: boolean): void {
	if (!button) {
		return;
	}
	button.dataset.busy = String(busy);
	button.disabled = busy;
	if (busy) {
		button.textContent = isRegister ? 'Creating…' : 'Connecting…';
		return;
	}
	button.textContent = isRegister ? 'Create protected account →' : 'Sign in securely →';
}

/** Handles a validated registration request. */
async function processPortalRegistration(elements: PortalFormElements, turnstileToken: string): Promise<void> {
	const result = await registerPortalAccount(elements.email.value, elements.password.value, turnstileToken, portalRegistrationProfile(elements));
	const message = humanAuthMessage(result.message);
	if (result.ok) {
		notifyWithMascot({
			kind: 'success',
			title: 'Account created',
			message: authConfig.requireEmailVerification ? 'Check your email to confirm your address before signing in.' : 'Development account created. You can sign in now.',
			duration: 7000,
		});
		setMountedMascotMood('excited', 2000);
		announce(authConfig.requireEmailVerification ? 'Account created. Check your email before signing in.' : 'Development account created. You can sign in now.');
		return;
	}
	if (result.status === 429) {
		notifyWithMascot({
			kind: 'warning',
			title: 'Too many attempts',
			message: 'You have been temporarily blocked. Please wait a few minutes.',
			duration: 9000,
		});
		return;
	}
	if (result.status === 422 && messageMentions(message, 'user already registered', 'already registered', 'already exists')) {
		notifyWithMascot({
			kind: 'info',
			title: 'Account already exists',
			message: 'An account with this email already exists. Try signing in instead.',
			duration: 6000,
		});
		return;
	}
	if (result.status === 409 || messageMentions(message, 'already registered', 'already taken', 'unique')) {
		notifyWithMascot({
			kind: 'warning',
			title: 'Choose another identity',
			message,
			duration: 7000,
		});
		return;
	}
	notifyWithMascot({
		kind: 'error',
		title: 'Registration failed',
		message,
		duration: 8000,
	});
	announce('Registration failed. Check the form and try again.');
}

/** Handles a validated login request. */
async function processPortalLogin(elements: PortalFormElements, turnstileToken: string): Promise<void> {
	const authenticated = await authenticatePortalLogin(elements.email.value, elements.password.value, turnstileToken);
	const message = humanAuthMessage(authenticated.message);
	if (!authenticated.ok) {
		if (authenticated.status === 429) {
			notifyWithMascot({
				kind: 'warning',
				title: 'Too many attempts',
				message: 'You have been temporarily blocked. Please wait a few minutes.',
				duration: 9000,
			});
			return;
		}
		if (messageMentions(message, 'email not confirmed', 'not confirmed', 'confirm your email')) {
			notifyWithMascot({
				kind: 'warning',
				title: 'Email not confirmed',
				message: 'Please check your inbox and click the confirmation link first.',
				duration: 9000,
			});
			return;
		}
		if (authenticated.status === 422 || authenticated.status === 400 || authenticated.status === 401) {
			notifyWithMascot({
				kind: 'error',
				title: 'Incorrect email or password',
				message: 'Double-check your credentials and try again.',
				duration: 8000,
			});
			setMountedMascotMood('scared', 1200);
			announce('Incorrect email or password.');
			return;
		}
		notifyWithMascot({
			kind: 'error',
			title: 'Connection failed',
			message,
			duration: 8000,
		});
		return;
	}
	await syncStoredConsents(authenticated.accessToken ?? '', elements.email.value);
	if (elements.newsletterConsent?.checked) {
		await requestNewsletterSubscription(elements.email.value).catch(() => undefined);
	}
	notifyWithMascot({
		kind: 'success',
		title: 'Welcome back',
		message: `Signed in as ${elements.email.value}`,
		duration: 4000,
	});
	setMountedMascotMood('happy', 1800);
	announce('Successfully connected — welcome back.');
	globalThis.setTimeout(() => closePortal(), 1200);
}

/** Handles the standard login variant of the portal form. */
async function submitPortalLogin(portal: HTMLElement, elements: PortalFormElements): Promise<void> {
	const isRegister = portal.dataset.authMode === 'register';
	const turnstileToken = validatePortalAuth(portal, elements, isRegister);
	if (!turnstileToken) {
		return;
	}
	setPortalSubmitBusy(elements.submitButton, true, isRegister);
	try {
		if (isRegister) {
			await processPortalRegistration(elements, turnstileToken);
			return;
		}
		await processPortalLogin(elements, turnstileToken);
	} catch {
		notifyWithMascot({
			kind: 'error',
			title: 'Connection failed',
			message: 'Could not reach the server. Check your connection and try again.',
			duration: 8000,
		});
		setMountedMascotMood('scared', 1200);
		announce('Connection failed — please check your credentials.');
	} finally {
		setPortalSubmitBusy(elements.submitButton, false, portal.dataset.authMode === 'register');
	}
}

/** Updates portal heading and call-to-action copy for the selected auth mode. */
function syncAuthModeCopy(controls: AuthModeControls, authMode: 'login' | 'register'): void {
	const isLogin = authMode === 'login';
	const registerNote = authConfig.requireEmailVerification
		? 'Create an account with email verification before opening your workspace.'
		: 'Create a local development account and open your workspace.';
	if (controls.authTitle instanceof HTMLElement) {
		controls.authTitle.textContent = isLogin ? 'Open your workspace' : 'Create your workspace';
	}
	if (controls.authNote instanceof HTMLElement) {
		controls.authNote.textContent = isLogin ? 'Sign in to connect Prismatica with the osionos app.' : registerNote;
	}
	if (controls.submitButton instanceof HTMLButtonElement) {
		controls.submitButton.textContent = isLogin ? 'Sign in securely →' : 'Create protected account →';
	}
}

/** Shows the relevant login or registration controls. */
function syncAuthModeVisibility(portal: HTMLElement, authMode: 'login' | 'register'): void {
	const isLogin = authMode === 'login';
	portal.querySelectorAll('.portal-register-only, .portal-consent').forEach((element) => {
		if (element instanceof HTMLElement) {
			element.hidden = isLogin;
		}
	});
	portal.querySelectorAll('.portal-login-only').forEach((element) => {
		if (element instanceof HTMLElement) {
			element.hidden = !isLogin;
		}
	});
	portal.querySelectorAll('[data-auth-switch]').forEach((button) => {
		if (button instanceof HTMLElement) {
			button.setAttribute('aria-pressed', String(button.dataset.authSwitch === authMode));
		}
	});
}

/** Updates required/autocomplete states for dynamic auth inputs. */
function syncAuthModeInputs(controls: AuthModeControls, authMode: 'login' | 'register'): void {
	const isLogin = authMode === 'login';
	if (controls.email instanceof HTMLInputElement) {
		controls.email.placeholder = isLogin ? 'you@example.com' : 'you@company.com';
	}
	[controls.username, controls.confirmPassword, controls.termsConsent].forEach((field) => {
		if (field instanceof HTMLInputElement) {
			field.required = !isLogin;
		}
	});
	if (controls.emailVerificationConsent instanceof HTMLInputElement) {
		controls.emailVerificationConsent.required = !isLogin && authConfig.requireEmailVerification;
	}
	if (controls.password instanceof HTMLInputElement) {
		controls.password.setAttribute('autocomplete', isLogin ? 'current-password' : 'new-password');
		controls.password.placeholder = isLogin ? 'Your password' : '8+ chars, A–z, 0–9, symbol';
	}
}

/** Closes any active portal (native <dialog>). */
function closePortal(): void {
	const portal = queryElement('.portal', isHtmlElement);
	if (!portal) {
		return;
	}
	mascotState.releaseFocusTrap?.();
	mascotState.releaseFocusTrap = null;
	if (portal instanceof HTMLDialogElement && portal.open) {
		portal.close();
	}
	portal.remove();
	document.body.classList.remove('portal-open');
	announce('Workspace portal closed');
	mascotState.previousFocus?.focus({ preventScroll: true });
	mascotState.previousFocus = null;
}

/** Opens the generated portal as a native modal dialog. */
function openPortal(mode: PortalMode): void {
	closePortal();
	mascotState.previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
	insertTrustedHTML(document.body, 'beforeend', createPortalMarkup(mode));
	const portal = queryElement('.portal', isHtmlElement);
	if (!portal) {
		return;
	}
	bindPasswordToggles(portal);
	ensureButtonLabels();
	document.body.classList.add('portal-open');
	announce('Workspace portal opened');
	requestAnimationFrame(() => portal.classList.add('is-revealed'));
	portal.querySelector('[data-close-portal]')?.addEventListener('click', closePortal);
	// Native <dialog> handles ESC, focus management, inert background, and the
	// top layer for us. We still listen to the close event for symmetric cleanup.
	if (portal instanceof HTMLDialogElement) {
		portal.addEventListener('close', () => {
			document.body.classList.remove('portal-open');
			mascotState.previousFocus?.focus({ preventScroll: true });
			mascotState.previousFocus = null;
		}, { once: true });
		// Backdrop click closes the dialog.
		portal.addEventListener('click', (event) => {
			if (event.target === portal) {
				portal.close();
			}
		});
		try {
			portal.showModal();
		} catch {
			// Already open or not connected; nothing to do.
		}
	}
	const initialTermsConsent = portal.querySelector('#portal-terms-consent');
	const initialSubmitButton = portal.querySelector('.portal-cta');
	const authModeControls: AuthModeControls = {
		authTitle: portal.querySelector('[data-auth-title]'),
		authNote: portal.querySelector('[data-auth-note]'),
		submitButton: initialSubmitButton,
		termsConsent: initialTermsConsent,
		email: portal.querySelector('#portal-email'),
		username: portal.querySelector('#portal-username'),
		emailVerificationConsent: portal.querySelector('#portal-email-verification-consent'),
		password: portal.querySelector('#portal-password'),
		confirmPassword: portal.querySelector('#portal-password-confirm'),
	};
	const refreshPortalValidation = (): void => {
		const elements = portalFormElements(portal);
		if (elements) {
			updatePortalSubmitAvailability(portal, elements);
		}
	};
	let availabilityTimer: number | undefined;
	let availabilityRequest = 0;
	const scheduleAvailabilityCheck = (): void => {
		if (availabilityTimer !== undefined) {
			globalThis.clearTimeout(availabilityTimer);
		}
		const elements = portalFormElements(portal);
		if (!elements || portal.dataset.authMode !== 'register') {
			setPortalAvailabilityState(portal, 'email', 'unknown');
			setPortalAvailabilityState(portal, 'username', 'unknown');
			refreshPortalValidation();
			return;
		}
		const usernameState = elements.username ? usernameValidationState(elements.username) : { valid: true, message: '', state: 'idle' as FieldValidationState };
		if (elements.username && usernameState.state !== 'idle') {
			showInlineFieldMessage(elements.username, usernameState.message, usernameState.state);
		}
		if (!usernameState.valid || !hasValidEmailFormat(elements.email)) {
			setPortalAvailabilityState(portal, 'username', usernameState.valid ? 'unknown' : 'taken');
			setPortalAvailabilityState(portal, 'email', hasValidEmailFormat(elements.email) ? 'unknown' : 'taken');
			refreshPortalValidation();
			return;
		}
		setPortalAvailabilityState(portal, 'email', 'checking');
		setPortalAvailabilityState(portal, 'username', 'checking');
		showInlineFieldMessage(elements.email, 'Checking email availability…', 'warning');
		if (elements.username) {
			showInlineFieldMessage(elements.username, 'Checking username availability…', 'warning');
		}
		refreshPortalValidation();
		const requestId = ++availabilityRequest;
		availabilityTimer = globalThis.setTimeout(() => {
			void authClient.availability(elements.email.value, elements.username?.value ?? '').then((availability) => {
				if (requestId !== availabilityRequest || portal.dataset.authMode !== 'register') {
					return;
				}
				setPortalAvailabilityState(portal, 'email', availability.email.available === false ? 'taken' : 'available');
				setPortalAvailabilityState(portal, 'username', availability.username.available === false ? 'taken' : 'available');
				showAvailabilityResult(elements.email, availability.email);
				if (elements.username) {
					showAvailabilityResult(elements.username, availability.username);
				}
				refreshPortalValidation();
			}).catch(() => {
				if (requestId !== availabilityRequest) {
					return;
				}
				setPortalAvailabilityState(portal, 'email', 'unknown');
				setPortalAvailabilityState(portal, 'username', 'unknown');
				refreshPortalValidation();
			});
		}, 350);
	};
	const setAuthMode = (authMode: 'login' | 'register'): void => {
		portal.dataset.authMode = authMode;
		syncAuthModeCopy(authModeControls, authMode);
		syncAuthModeVisibility(portal, authMode);
		syncAuthModeInputs(authModeControls, authMode);
		scheduleAvailabilityCheck();
		refreshPortalValidation();
	};
	if (initialTermsConsent instanceof HTMLInputElement) {
		initialTermsConsent.addEventListener('change', () => {
			refreshPortalValidation();
			initialTermsConsent.removeAttribute('aria-invalid');
			initialTermsConsent.removeAttribute('aria-describedby');
		});
	}
	portal.querySelectorAll('[data-auth-switch]').forEach((button) => {
		if (button instanceof HTMLElement) {
			button.addEventListener('click', () => setAuthMode(button.dataset.authSwitch === 'login' ? 'login' : 'register'));
		}
	});
	bindEmailFieldValidation(portal);
	setAuthMode(mode === 'connect' ? 'login' : 'register');
	mountTurnstile(portal);
	const passwordField = portal.querySelector('[data-password-field]');
	const passwordInput = portal.querySelector('#portal-password');
	const forgotPassword = portal.querySelector('[data-forgot-password]');
	const recoveryActions = portal.querySelector('[data-recovery-actions]');
	const cancelRecovery = portal.querySelector('[data-cancel-recovery]');
	const closePortalButton = portal.querySelector('[data-close-portal]');
	[passwordInput, portal.querySelector('#portal-password-confirm')].forEach((field) => {
		if (field instanceof HTMLInputElement) {
			field.addEventListener('input', refreshPortalValidation);
		}
	});
	const setRecoveryMode = (enabled: boolean): void => {
		portal.dataset.portalMode = enabled ? 'recovery' : 'login';
		if (passwordField instanceof HTMLElement) {
			passwordField.hidden = enabled;
		}
		if (passwordInput instanceof HTMLInputElement) {
			passwordInput.required = !enabled;
			passwordInput.value = enabled ? '' : passwordInput.value;
		}
		if (initialSubmitButton instanceof HTMLButtonElement) {
			initialSubmitButton.hidden = enabled;
		}
		if (recoveryActions instanceof HTMLElement) {
			recoveryActions.hidden = !enabled;
		}
		if (closePortalButton instanceof HTMLElement) {
			closePortalButton.hidden = enabled;
		}
		portal.querySelectorAll('.portal-consent, .portal-register-only').forEach((element) => {
			if (element instanceof HTMLElement) {
				element.hidden = enabled || portal.dataset.authMode === 'login';
			}
		});
		portal.querySelectorAll('.portal-login-only').forEach((element) => {
			if (element instanceof HTMLElement) {
				element.hidden = enabled || portal.dataset.authMode === 'register';
			}
		});
		const error = portal.querySelector('.portal-error');
		if (error instanceof HTMLOutputElement) {
			error.textContent = '';
		}
		queryElement('#portal-email', isInput)?.focus();
		refreshPortalValidation();
	};
	if (forgotPassword instanceof HTMLButtonElement) {
		forgotPassword.addEventListener('click', () => setRecoveryMode(true));
	}
	if (cancelRecovery instanceof HTMLButtonElement) {
		cancelRecovery.addEventListener('click', () => setRecoveryMode(false));
	}
	portal.querySelector('.portal-login')?.addEventListener('submit', (event) => {
		event.preventDefault();
		const elements = portalFormElements(portal);
		if (!elements) {
			return;
		}
		void (portal.dataset.portalMode === 'recovery' ? submitPortalRecovery(portal, elements) : submitPortalLogin(portal, elements));
	});
	portal.querySelectorAll('input').forEach((field) => {
		field.addEventListener('input', () => {
			if (field instanceof HTMLInputElement && field.type === 'email') {
				scheduleAvailabilityCheck();
				refreshPortalValidation();
				return;
			}
			if (field instanceof HTMLInputElement && field.id === 'portal-username') {
				scheduleAvailabilityCheck();
			}
			if (field instanceof HTMLInputElement && field.validity.valid) {
				field.removeAttribute('aria-invalid');
				field.removeAttribute('aria-describedby');
			}
			refreshPortalValidation();
		});
	});
	refreshPortalValidation();
	queryElement('#portal-email', isInput)?.focus();
}

/** Installs the consent banner controls. */
function bindConsentBanner(): void {
	const banner = queryElement('[data-consent-banner]', isHtmlElement);
	if (!banner) {
		return;
	}
	const form = banner.querySelector('[data-consent-form]');
	const manageButton = banner.querySelector('[data-consent-manage]');
	const acceptAll = banner.querySelector('[data-consent-accept-all]');
	const rejectAll = banner.querySelector('[data-consent-reject-all]');
	const showBanner = (): void => banner.removeAttribute('hidden');
	const hideBanner = (): void => banner.setAttribute('hidden', '');
	const save = (analytics: boolean, newsletter: boolean, marketing: boolean): void => {
		storeConsentPreferences({ analytics, newsletter, marketing });
		hideBanner();
		announce('Consent preferences saved.');
	};

	if (!readConsentPreferences()) {
		showBanner();
	}

	queryElements('[data-manage-cookies]', isButton).forEach((button) => button.addEventListener('click', () => {
		showBanner();
		banner.focus({ preventScroll: false });
	}));

	if (manageButton instanceof HTMLButtonElement && form instanceof HTMLFormElement) {
		manageButton.addEventListener('click', () => {
			const isExpanded = manageButton.getAttribute('aria-expanded') === 'true';
			manageButton.setAttribute('aria-expanded', String(!isExpanded));
			form.hidden = isExpanded;
		});

		form.addEventListener('submit', (event) => {
			event.preventDefault();
			const analytics = form.elements.namedItem('analytics');
			const newsletter = form.elements.namedItem('newsletter');
			const marketing = form.elements.namedItem('marketing');
			save(
				analytics instanceof HTMLInputElement && analytics.checked,
				newsletter instanceof HTMLInputElement && newsletter.checked,
				marketing instanceof HTMLInputElement && marketing.checked,
			);
		});
	}

	acceptAll?.addEventListener('click', () => save(true, true, true));
	rejectAll?.addEventListener('click', () => save(false, false, false));
}

/** Installs newsletter opt-in form handlers. */
function bindNewsletterSignup(): void {
	queryElements('[data-newsletter-signup]', isHtmlElement).forEach((form) => {
		if (!(form instanceof HTMLFormElement)) {
			return;
		}
		bindEmailFieldValidation(form);
		form.addEventListener('submit', async (event) => {
			event.preventDefault();
			const email = form.elements.namedItem('email');
			const checkbox = form.elements.namedItem('newsletter_consent');
			const status = form.querySelector('[data-newsletter-status]');
			const button = form.querySelector('button[type="submit"]');
			if (!(email instanceof HTMLInputElement) || !(checkbox instanceof HTMLInputElement) || !(status instanceof HTMLOutputElement) || !(button instanceof HTMLButtonElement)) {
				return;
			}
			if (!validateEmailField(email, 'Please enter your email address')) {
				status.textContent = 'Please enter a valid email address (e.g. you@example.com)';
				email.focus();
				return;
			}
			if (!checkbox.checked) {
				status.textContent = 'Please tick the newsletter consent box to subscribe.';
				notifyWithMascot({
					kind: 'warning',
					title: 'Consent required',
					message: 'Please tick the newsletter consent box to subscribe.',
					duration: 5000,
				});
				checkbox.focus();
				return;
			}
			button.disabled = true;
			const previousText = button.textContent ?? 'Subscribe';
			button.textContent = 'Sending…';
			status.textContent = 'Sending your newsletter request…';
			setMountedMascotMood('listening', 1600);
			try {
				const response = await requestNewsletterSubscription(email.value);
				if (response.ok) {
					writeStorage(NEWSLETTER_INTENT_KEY, JSON.stringify({ email: email.value.trim(), pendingDoubleOptIn: true, policyVersion: POLICY_VERSION, savedAt: new Date().toISOString() }));
					status.textContent = response.message;
					notifyWithMascot({
						kind: 'success',
						title: 'Almost there!',
						message: response.message,
						duration: 0,
					});
					return;
				}
				throw new Error(response.message);
			} catch (error) {
				const message = error instanceof Error && error.message !== 'newsletter_failed' ? error.message : 'Could not send. Please try again or contact us directly.';
				status.textContent = message;
				notifyWithMascot({
					kind: 'error',
					title: 'Could not send',
					message,
					duration: 8000,
				});
			} finally {
				button.disabled = false;
				button.textContent = previousText;
			}
		});
	});
}

/** Reads a string value from FormData without accepting File object stringification. */
function formDataString(formData: FormData, key: string): string {
	const value = formData.get(key);
	return typeof value === 'string' ? value : '';
}

/** Installs the public data-rights request form. */
function bindDataRightsForm(): void {
	const form = queryElement('[data-gdpr-request-form]', isHtmlElement);
	if (!(form instanceof HTMLFormElement)) {
		return;
	}
	let csrf = readStorage(CSRF_STORAGE_KEY);
	if (!csrf) {
		csrf = crypto.randomUUID();
		writeStorage(CSRF_STORAGE_KEY, csrf);
	}
	const csrfInput = form.querySelector('[data-csrf-token]');
	if (csrfInput instanceof HTMLInputElement) {
		csrfInput.value = csrf;
	}
	form.addEventListener('submit', async (event) => {
		event.preventDefault();
		const status = form.querySelector('[data-gdpr-request-status]');
		const formData = new FormData(form);
		if (!(status instanceof HTMLOutputElement)) {
			return;
		}
		if (formData.get('csrf') !== csrf) {
			status.textContent = 'Security token mismatch. Refresh and try again.';
			return;
		}
		const response = await callGdprRpc('gdpr_submit_request', {
			request_type: formDataString(formData, 'request_type'),
			email: formDataString(formData, 'email'),
			details: { message: formDataString(formData, 'message'), csrf, policyVersion: POLICY_VERSION },
		}).catch(() => null);
		status.textContent = response?.ok ? 'Your request has been recorded. We may contact you to verify identity.' : 'Could not record the request right now.';
	});
}

/** Moves keyboard focus to meaningful content when the skip link is used. */
function removeTemporaryTabindex(element: HTMLElement, shouldRemove: boolean): void {
	if (shouldRemove) {
		element.removeAttribute('tabindex');
	}
}

function focusSkipTarget(focusTarget: HTMLElement, removeTabindexOnBlur: boolean): void {
	focusTarget.focus({ preventScroll: true });
	focusTarget.addEventListener('blur', () => removeTemporaryTabindex(focusTarget, removeTabindexOnBlur), { once: true });
}

function handleSkipLinkClick(event: Event): void {
	const link = event.currentTarget;
	if (!(link instanceof HTMLAnchorElement)) {
		return;
	}
	const target = document.getElementById(link.hash.slice(1));
	if (!(target instanceof HTMLElement)) {
		return;
	}
	const focusTarget = target.querySelector('h1, h2, [tabindex], a[href], button, input, select, textarea') ?? target;
	if (!(focusTarget instanceof HTMLElement)) {
		return;
	}
	const hadTabindex = focusTarget.hasAttribute('tabindex');
	if (!hadTabindex) {
		focusTarget.setAttribute('tabindex', '-1');
	}
	requestAnimationFrame(() => focusSkipTarget(focusTarget, !hadTabindex));
}

function bindSkipLinkFocus(): void {
	queryElements('.skip-link[href^="#"]', (element): element is HTMLAnchorElement => element instanceof HTMLAnchorElement).forEach((link) => {
		link.addEventListener('click', handleSkipLinkClick);
	});
}

/** Installs document-level interaction handlers. */
function bindInteractions(): void {
		queryElement('#theme-toggle', isButton)?.addEventListener('click', cycleTheme);
		queryElements('[data-theme-toggle]', isButton).forEach((button) => button.addEventListener('click', cycleTheme));
	queryElement('#pause-animations', isButton)?.addEventListener('click', () => applyMotionPreference(!document.documentElement.classList.contains('motion-paused')));
	bindSkipLinkFocus();
	bindEmailFieldValidation(document);
	bindConsentBanner();
	bindNewsletterSignup();
	bindDataRightsForm();
	queryElements('[data-open-portal]', isButton).forEach((button) => button.addEventListener('click', () => openPortal('start')));
	queryElements('[data-open-connect]', isButton).forEach((button) => button.addEventListener('click', () => openPortal('connect')));
	document.addEventListener('keydown', (event) => {
		if (event.key === 'Escape') {
			closePortal();
		}
	});
	window.addEventListener('resize', renderPaperGrain);
}

/** Loads seeded BaaS data into the frontend status card. */
async function mountBaasStatus(): Promise<void> {
	const root = queryElement('[data-baas-status]', isHtmlElement);
	if (!root) {
		return;
	}

	const state = root.querySelector('[data-baas-state]');
	const list = root.querySelector('[data-baas-users]');
	if (!(state instanceof HTMLElement) || !(list instanceof HTMLUListElement)) {
		return;
	}

	try {
		const users = await fetchSeededUsers(3);
		state.textContent = `Connected securely — loaded ${users.length} seeded users.`;
		list.replaceChildren(
			...users.map((user) => {
				const item = document.createElement('li');
				const name = document.createElement('strong');
				const email = document.createElement('span');
				name.textContent = user.username;
				email.textContent = user.email;
				item.append(name, email);
				return item;
			}),
		);
	} catch (error) {
		state.textContent = error instanceof Error ? error.message : 'Unable to reach the BaaS gateway.';
		list.replaceChildren();
	}
}

/** Starts all client-side page behavior. */
function init(): void {
	dismissAll();
	applyTheme(initialTheme());
	applyMotionPreference(readStorage(MOTION_KEY) === 'true');
	ensureButtonLabels();
	bindPasswordToggles();
	renderPaperGrain();
	mountMascot();
	bindInteractions();
	bindScrollReveal();
	void mountBaasStatus();
}

// ---------- Scroll reveal ----------

function bindScrollReveal(): void {
        if (typeof IntersectionObserver === 'undefined') return;
        if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
        const candidates = document.querySelectorAll<HTMLElement>('[data-scroll-rise], [data-scroll-grow], [data-reveal]');
        if (candidates.length === 0) return;
        const io = new IntersectionObserver((entries) => {
                for (const entry of entries) {
                        if (entry.isIntersecting) {
                                entry.target.classList.add('is-revealed');
                                io.unobserve(entry.target);
                        }
                }
        }, { threshold: 0.18, rootMargin: '0px 0px -8% 0px' });
        candidates.forEach((node) => {
                node.classList.add('reveal-prep');
                io.observe(node);
        });

}

init();

// Theme feature module.
// Reads a stored theme preference, applies it to <html data-theme>, and binds
// the theme toggle button. Safe to call multiple times — it is idempotent.

export type ThemeName = 'light' | 'dark' | 'night';

const STORAGE_KEY = 'prismatica:theme';
const THEMES: ThemeName[] = ['light', 'dark', 'night'];

function readStoredTheme(): ThemeName | null {
	try {
		const value = globalThis.localStorage?.getItem(STORAGE_KEY);
		return THEMES.includes(value as ThemeName) ? (value as ThemeName) : null;
	} catch {
		return null;
	}
}

function systemPreference(): ThemeName {
	return globalThis.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function persist(theme: ThemeName): void {
	try {
		globalThis.localStorage?.setItem(STORAGE_KEY, theme);
	} catch {
		// localStorage may be unavailable in private modes — silently degrade.
	}
}

export function applyTheme(theme: ThemeName): void {
	document.documentElement.dataset.theme = theme;
	persist(theme);
}

export function cycleTheme(): ThemeName {
	const current = (document.documentElement.dataset.theme as ThemeName | undefined) ?? 'light';
	const next = THEMES[(THEMES.indexOf(current) + 1) % THEMES.length];
	applyTheme(next);
	return next;
}

export function initTheme(): void {
	applyTheme(readStoredTheme() ?? systemPreference());
	document.addEventListener('click', (event) => {
		const target = event.target;
		if (!(target instanceof Element)) return;
		if (target.closest('[data-action="toggle-theme"]')) {
			cycleTheme();
		}
	});
}

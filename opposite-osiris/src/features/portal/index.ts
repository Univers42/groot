// Portal feature module.
// Owns the lazy injection of Cloudflare Turnstile and the wiring between
// `[data-action="open-portal-*"]` triggers and the dialog. Today it dispatches
// the same custom events main.ts already listens for, so both code paths can
// coexist while the legacy script is being retired.

export interface PortalInit {
	turnstileSrc?: string;
}

const TURNSTILE_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
let turnstileInjected = false;

function injectTurnstile(src: string): void {
	if (turnstileInjected) return;
	if (document.querySelector(`script[src^="${src.split('?')[0]}"]`)) {
		turnstileInjected = true;
		return;
	}
	const script = document.createElement('script');
	script.src = src;
	script.async = true;
	script.defer = true;
	document.head.appendChild(script);
	turnstileInjected = true;
}

function dispatchOpen(mode: 'start' | 'connect'): void {
	document.dispatchEvent(new CustomEvent('portal:open', { detail: { mode } }));
}

export function initPortal({ turnstileSrc = TURNSTILE_SRC }: PortalInit = {}): void {
	const root = document;
	root.addEventListener('click', (event) => {
		const target = event.target;
		if (!(target instanceof Element)) return;
		const trigger = target.closest<HTMLElement>('[data-action^="open-portal-"]');
		if (!trigger) return;
		event.preventDefault();
		const mode = trigger.dataset.action === 'open-portal-connect' ? 'connect' : 'start';
		injectTurnstile(turnstileSrc);
		dispatchOpen(mode);
	});
}

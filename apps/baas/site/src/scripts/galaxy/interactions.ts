// Pointer + keyboard paths into the galaxy. The hover/pin card is built with
// createElement/textContent only (trusted-types-safe, CSP-clean). The
// keyboard path lives in #galaxy-explorer: one real <button> per example
// tenant, mirrored to the role="status" line for screen readers.
import type { TenantNode } from './types.ts';

export interface InteractionHooks {
	setHighlight(index: number): void;
	requestRender(): void;
}

const ISOLATION_LABEL: Record<string, string> = {
	shared_rls: 'Shared RLS',
	schema_per_tenant: 'Schema per tenant',
	db_per_tenant: 'Database per tenant',
	tenant_owned: 'Tenant-owned database',
};

const HIT_RADIUS = 13;

function describe(node: TenantNode): string {
	return `${node.name} — ${node.tier} tier, engines: ${node.engines.join(', ')}, isolation: ${ISOLATION_LABEL[node.isolation]}.`;
}

function fillCard(card: HTMLElement, node: TenantNode): void {
	card.replaceChildren();
	const name = document.createElement('p');
	name.className = 'gb-galaxy-card__name';
	name.textContent = node.name;
	const tier = document.createElement('p');
	tier.className = `gb-galaxy-card__tier tier--${node.tier}`;
	tier.textContent = `${node.tier} tier`;
	const engines = document.createElement('p');
	engines.className = 'gb-galaxy-card__row';
	engines.textContent = `engines: ${node.engines.join(' · ')}`;
	const isolation = document.createElement('p');
	isolation.className = 'gb-galaxy-card__row';
	isolation.textContent = `isolation: ${ISOLATION_LABEL[node.isolation]}`;
	card.append(name, tier, engines, isolation);
}

function placeCard(card: HTMLElement, x: number, y: number): void {
	const pad = 16;
	const cw = card.offsetWidth || 240;
	const ch = card.offsetHeight || 120;
	let left = x + 18;
	let top = y - ch / 2;
	if (left + cw + pad > window.innerWidth) left = x - cw - 18;
	top = Math.max(pad, Math.min(top, window.innerHeight - ch - pad));
	card.style.left = `${Math.max(pad, left)}px`;
	card.style.top = `${top}px`;
}

/** Skip hover popups while the pointer is over readable content. */
function overContent(x: number, y: number): boolean {
	const el = document.elementFromPoint(x, y);
	return !!el?.closest('p, h1, h2, h3, a, button, pre, table, ul, ol, figure, details, input');
}

export function setupInteractions(nodes: TenantNode[], hooks: InteractionHooks): void {
	const card = document.getElementById('galaxy-card');
	const explorer = document.getElementById('galaxy-explorer');
	const status = document.getElementById('galaxy-status');
	if (!card) return;

	let pinned = -1;

	const show = (index: number, atNode: boolean, px = 0, py = 0) => {
		const node = nodes[index]!;
		fillCard(card, node);
		card.hidden = false;
		placeCard(card, atNode ? node.x : px, atNode ? node.y : py);
		hooks.setHighlight(index);
		hooks.requestRender();
	};

	const hide = () => {
		card.hidden = true;
		hooks.setHighlight(-1);
		hooks.requestRender();
	};

	const hitTest = (x: number, y: number): number => {
		let best = -1;
		let bestD = HIT_RADIUS * HIT_RADIUS;
		for (let i = 0; i < nodes.length; i += 1) {
			const dx = nodes[i]!.x - x;
			const dy = nodes[i]!.y - y;
			const d = dx * dx + dy * dy;
			if (d < bestD) {
				bestD = d;
				best = i;
			}
		}
		return best;
	};

	let rafPending = false;
	document.addEventListener('pointermove', (event) => {
		if (pinned >= 0 || rafPending) return;
		rafPending = true;
		requestAnimationFrame(() => {
			rafPending = false;
			const { clientX: x, clientY: y } = event;
			const hit = overContent(x, y) ? -1 : hitTest(x, y);
			if (hit >= 0) show(hit, true);
			else if (!card.hidden) hide();
		});
	});

	document.addEventListener('click', (event) => {
		if (overContent(event.clientX, event.clientY)) return;
		const hit = hitTest(event.clientX, event.clientY);
		if (hit >= 0) {
			pinned = pinned === hit ? -1 : hit;
			if (pinned >= 0) show(pinned, true);
			else hide();
		} else if (pinned >= 0) {
			pinned = -1;
			hide();
		}
	});

	document.addEventListener('keydown', (event) => {
		if (event.key === 'Escape' && pinned >= 0) {
			pinned = -1;
			hide();
		}
	});

	// Keyboard explorer: one representative tenant per tier + a tenant-owned one.
	if (!explorer || !status) return;
	const picks: number[] = [];
	for (const tier of ['nano', 'basic', 'essential', 'pro', 'max']) {
		const i = nodes.findIndex((n) => n.tier === tier);
		if (i >= 0) picks.push(i);
	}
	const owned = nodes.findIndex((n) => n.isolation === 'tenant_owned');
	if (owned >= 0 && !picks.includes(owned)) picks.push(owned);

	const buttons: HTMLButtonElement[] = [];
	for (const index of picks) {
		const node = nodes[index]!;
		const button = document.createElement('button');
		button.type = 'button';
		button.textContent = `${node.name} (${node.tier})`;
		button.setAttribute('aria-pressed', 'false');
		button.addEventListener('click', () => {
			const active = button.getAttribute('aria-pressed') === 'true';
			for (const b of buttons) b.setAttribute('aria-pressed', 'false');
			if (active) {
				pinned = -1;
				hide();
				status.textContent = '';
				return;
			}
			button.setAttribute('aria-pressed', 'true');
			pinned = index;
			show(index, true);
			status.textContent = describe(node);
		});
		buttons.push(button);
		explorer.append(button);
	}
	explorer.hidden = false;
}

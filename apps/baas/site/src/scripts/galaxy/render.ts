// Canvas2D frame renderer. DPR-aware (capped at 2), links then glow-sprite
// nodes; highlight ring for the hovered/focused tenant.
import type { TenantNode } from './types.ts';
import { glowSprite } from './sprite.ts';

export interface RenderState {
	links: Array<[number, number]>;
	highlight: number; // node index or -1
}

export function resizeCanvas(canvas: HTMLCanvasElement): { w: number; h: number } {
	const dpr = Math.min(window.devicePixelRatio || 1, 2);
	const w = window.innerWidth;
	const h = window.innerHeight;
	if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
		canvas.width = Math.round(w * dpr);
		canvas.height = Math.round(h * dpr);
	}
	const ctx = canvas.getContext('2d')!;
	ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	return { w, h };
}

export function renderFrame(ctx: CanvasRenderingContext2D, nodes: TenantNode[], state: RenderState, w: number, h: number): void {
	ctx.clearRect(0, 0, w, h);

	ctx.strokeStyle = 'rgba(148, 163, 198, 0.14)';
	ctx.lineWidth = 1;
	ctx.beginPath();
	for (const [a, b] of state.links) {
		const na = nodes[a]!;
		const nb = nodes[b]!;
		ctx.moveTo(na.x, na.y);
		ctx.lineTo(nb.x, nb.y);
	}
	ctx.stroke();

	for (const node of nodes) {
		const size = node.r * node.rScale * 4.6;
		ctx.drawImage(glowSprite(node.color), node.x - size / 2, node.y - size / 2, size, size);
	}

	if (state.highlight >= 0) {
		const node = nodes[state.highlight]!;
		ctx.strokeStyle = node.tierColor;
		ctx.lineWidth = 1.6;
		ctx.beginPath();
		ctx.arc(node.x, node.y, node.r * node.rScale * 3 + 5, 0, Math.PI * 2);
		ctx.stroke();
	}
}

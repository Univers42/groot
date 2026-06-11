// Galaxy entry point. Never competes with LCP: init is deferred to idle time,
// the loop pauses when the tab is hidden, and prefers-reduced-motion gets
// static frames (one render per narrative state) instead of animation.
import type { LayoutState, TenantNode } from './types.ts';
import { seedTenants } from './seed.ts';
import { computeLayout } from './layouts.ts';
import { applyLayoutTargets, snapToTargets, step } from './physics.ts';
import { renderFrame, resizeCanvas, type RenderState } from './render.ts';
import { watchSections } from './scroll-director.ts';
import { setupInteractions } from './interactions.ts';

function init(): void {
	const canvas = document.getElementById('galaxy-canvas') as HTMLCanvasElement | null;
	if (!canvas) return;
	const ctx = canvas.getContext('2d');
	if (!ctx) return;

	const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	const nodes: TenantNode[] = seedTenants();
	const renderState: RenderState = { links: [], highlight: -1 };

	let { w, h } = resizeCanvas(canvas);
	let currentState: LayoutState = 'nebula';
	let running = false;
	let lastTime = 0;

	const drawOnce = () => renderFrame(ctx, nodes, renderState, w, h);

	const applyState = (state: LayoutState, instant: boolean) => {
		currentState = state;
		const layout = computeLayout(state, nodes, w, h);
		applyLayoutTargets(nodes, layout.targets, layout.rScales, performance.now());
		renderState.links = layout.links;
		if (instant || reducedMotion) {
			snapToTargets(nodes, performance.now());
			drawOnce();
		}
	};

	const frame = (time: number) => {
		if (!running) return;
		const dt = lastTime === 0 ? 16 : time - lastTime;
		lastTime = time;
		step(nodes, dt, time);
		drawOnce();
		requestAnimationFrame(frame);
	};

	const start = () => {
		if (running || reducedMotion) return;
		running = true;
		lastTime = 0;
		requestAnimationFrame(frame);
	};

	const stop = () => {
		running = false;
	};

	// First paint: settle directly into the hero nebula.
	applyState('nebula', true);
	start();

	watchSections((state) => {
		if (state !== currentState) applyState(state, false);
	});

	setupInteractions(nodes, {
		setHighlight: (index) => {
			renderState.highlight = index;
		},
		requestRender: () => {
			if (!running) drawOnce();
		},
	});

	let resizeTimer = 0;
	window.addEventListener('resize', () => {
		window.clearTimeout(resizeTimer);
		resizeTimer = window.setTimeout(() => {
			({ w, h } = resizeCanvas(canvas));
			applyState(currentState, true);
		}, 160);
	});

	document.addEventListener('visibilitychange', () => {
		if (document.hidden) stop();
		else start();
	});
}

// Defer init off the critical path (the H1 is the LCP element, not the galaxy).
if (document.getElementById('galaxy-canvas')) {
	if (typeof window.requestIdleCallback === 'function') {
		window.requestIdleCallback(() => init(), { timeout: 1500 });
	} else {
		setTimeout(init, 300);
	}
}

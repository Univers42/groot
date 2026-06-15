// ── Hero scene animator — cross-browser (Firefox-safe) SVG motion.
//
// Firefox renders CSS `transform` animations on SVG elements (with
// `transform-box: fill-box` + `transform-origin`) inconsistently, so the leg /
// hills / shooting-star sat frozen there. SMIL is blocked by the icon-safety
// gate. The robust answer: drive the transforms from JS in a requestAnimationFrame
// loop via setAttribute — plain DOM writes that behave identically in every
// engine. CSP-safe (no innerHTML / eval, attribute writes only). Star twinkle
// stays a CSS opacity animation (cross-browser fine). Respects reduced-motion:
// when the user prefers reduced motion we leave the scene as a calm static night.

const KX = 30; // knee pivot X in the leg's local coords (matches path M30 -6)
const KY = -6; // knee pivot Y
const TWO_PI = Math.PI * 2;

function init(): void {
	const leg = document.querySelector<SVGGElement>('.gb-scene__leg');
	if (!leg) return; // no scene on this page

	const hillBack = document.querySelector<SVGPathElement>('.gb-scene__hill--back');
	const hillMid = document.querySelector<SVGPathElement>('.gb-scene__hill--mid');
	const shoot = document.querySelector<SVGGElement>('.gb-scene__shoot');
	const moonRim = document.querySelector<SVGGElement>('.gb-scene__moon-rim');
	const fog = document.querySelector<SVGGElement>('.gb-scene__fog');

	const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

	// A pleasant resting frame for reduced-motion (and the no-JS default already
	// renders the scene at rest, so this just confirms it).
	function rest(): void {
		leg!.setAttribute('transform', `rotate(6 ${KX} ${KY})`);
		if (shoot) shoot.setAttribute('opacity', '0');
	}

	let raf = 0;
	function frame(t: number): void {
		const s = t / 1000;

		// leg swing: a gentle pendulum, −13°..+24°, ~2.3s period, pivot at the knee
		const a = 5.5 + 18.5 * Math.sin(s * (TWO_PI / 2.3));
		leg!.setAttribute('transform', `rotate(${a.toFixed(2)} ${KX} ${KY})`);

		// slow parallax drift of the hill layers (kept within the 40px overscan)
		if (hillBack) hillBack.setAttribute('transform', `translate(${(Math.sin(s / 6) * -12).toFixed(1)} 0)`);
		if (hillMid) hillMid.setAttribute('transform', `translate(${(Math.sin(s / 8 + 1) * 9).toFixed(1)} 0)`);

		// the neon moon rim breathes
		if (moonRim) moonRim.setAttribute('opacity', (0.55 + 0.35 * Math.sin(s * 0.9)).toFixed(2));

		// fog wisps drift slowly across the hills
		if (fog) fog.setAttribute('transform', `translate(${(Math.sin(s / 11) * 26).toFixed(1)} 0)`);

		// a shooting star streaks across every ~9s
		if (shoot) {
			const c = (s % 9) / 9;
			if (c < 0.14) {
				const k = c / 0.14;
				shoot.setAttribute('transform', `translate(${(k * 260).toFixed(0)} ${(k * 140).toFixed(0)})`);
				shoot.setAttribute('opacity', (k < 0.2 ? (k * 4.5).toFixed(2) : (1 - k).toFixed(2)));
			} else {
				shoot.setAttribute('opacity', '0');
			}
		}

		raf = window.requestAnimationFrame(frame);
	}

	function start(): void {
		if (reduce.matches) {
			window.cancelAnimationFrame(raf);
			raf = 0;
			rest();
		} else if (!raf) {
			raf = window.requestAnimationFrame(frame);
		}
	}

	start();
	// react live if the user toggles the OS reduced-motion setting
	reduce.addEventListener?.('change', start);
}

if (document.readyState !== 'loading') init();
else document.addEventListener('DOMContentLoaded', init);

// Maps scroll position to a narrative LayoutState: the section whose band
// crosses the viewport's middle wins. IntersectionObserver only — no scroll
// listeners, no layout thrash.
import type { LayoutState } from './types.ts';

export function watchSections(onState: (state: LayoutState) => void): void {
	const sections = Array.from(document.querySelectorAll<HTMLElement>('[data-galaxy-state]'));
	if (sections.length === 0) return;
	const observer = new IntersectionObserver(
		(entries) => {
			for (const entry of entries) {
				if (entry.isIntersecting) {
					const state = (entry.target as HTMLElement).dataset.galaxyState as LayoutState;
					if (state) onState(state);
				}
			}
		},
		{ rootMargin: '-42% 0px -42% 0px', threshold: 0 },
	);
	for (const section of sections) observer.observe(section);
}

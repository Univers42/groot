# Prismatica WCAG implementation checklist

## Perceivable
- [x] All non-text content has a text alternative.
	- Informative `img` assets in the Visual workspace library use meaningful `alt` text.
	- Decorative SVG, canvas grain, stars, arrows, and character art are marked with `aria-hidden="true"` and `focusable="false"`.
- [x] CAPTCHA is not present. If added later, it must include a non-visual alternative such as audio or a support path.
- [x] Time-based media is not present. If audio/video is added later, provide captions, transcripts, and audio descriptions where needed.
- [x] Content can be presented in different ways without losing structure.
	- Semantic landmarks: `header`, `nav`, `main`, `section`, `article`, `footer`.
	- Responsive layouts and orientation-safe modal styles are present.
	- The skip link targets a focusable `main` element.
- [x] Content can be separated from its background.
	- Root CSS tokens support `light`, `dark`, and `night` themes.
	- Main foreground/background contrast ratios are above WCAG AA thresholds.
	- Mascot, portal, card, and sketch colours now use theme-aware tokens instead of fixed light-only colours.
- [x] Contrast ratio targets: normal text >= 4.5:1 and large text/non-text UI >= 3:1.
- [x] Text can be resized up to 200% without loss of core content or functionality.
	- Layout uses responsive grids, wrapping actions, `clamp()`, and relative text sizing.
- [x] Background audio is not present.
- [x] Content does not flash more than three times per second.
	- Decorative animation can be paused and is disabled for `prefers-reduced-motion`.

## Operable
- [x] The full website is visitable by keyboard only.
	- Native links/buttons are used for navigation/actions.
	- `Tab` moves through controls, `Enter`/`Space` activate controls.
	- `ArrowUp`, `ArrowDown`, `PageUp`, `PageDown`, `Home`, and `End` scroll the page when focus is not in an editable field or modal.
- [x] Header actions use compact icon buttons with short accessible names.
	- Icons are decorative (`aria-hidden`) and each button keeps a clear `aria-label`, tooltip, and keyboard activation.
- [x] Users can pause, stop, or reduce movement.
	- Header `Pause animations` control toggles decorative motion.
	- `prefers-reduced-motion: reduce` disables non-essential animation.
- [x] Users are not trapped in a part of the website.
	- Portal dialog traps focus while open, supports `Escape`, and returns focus to the opener on close.
- [x] Users can navigate, find content, and determine where they are.
	- Skip link, headings, section labels, navigation links, and visible focus states are present.
- [x] Users can predict interactions.
	- Buttons use visible action text and state changes are announced through `aria-live`.
- [x] Input modalities are available.
	- Pointer, touch, keyboard, and assistive technology flows use native controls.

## Understandable
- [x] Language is declared.
	- Page language is `en`; French labels use `lang="fr"`.
- [x] Technical terms have simple explanations.
	- `DBMS` uses `abbr title` with a plain-language expansion.
- [x] Error prevention and correction are supported.
	- Login form validates email/password, sets `aria-invalid`, links errors with `aria-describedby`, and focuses the field to correct.

## Robust
- [x] Assistive technologies can access and use the content.
	- Semantic HTML is preferred over custom roles.
	- ARIA is used for dialog state, live announcements, explicit labels, and hidden decorative content.
- [x] Current and future assistive technologies are supported.
	- Valid landmarks, unique SVG IDs for cloned content, and focus management are used.

## References
- https://www.youtube.com/watch?v=RjpvOqZigao&t=82s

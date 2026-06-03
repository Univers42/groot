// Flat ESLint config for the opposite-osiris (Prismatica) Astro site.
// Run inside Docker only: `npm run lint` (wrapped by scripts/container-only.mjs).
//
// Layers:
//   - @eslint/js recommended            → core JS correctness
//   - typescript-eslint recommended     → TS correctness (syntactic, no type info)
//   - eslint-plugin-astro recommended   → .astro component correctness
//   - astro jsx-a11y-recommended        → accessibility lint for .astro templates
import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import astro from 'eslint-plugin-astro';

export default tseslint.config(
	{
		ignores: [
			'dist/',
			'.astro/',
			'node_modules/',
			'public/',
			'**/*.min.*',
			'package-lock.json',
		],
	},
	js.configs.recommended,
	...tseslint.configs.recommended,
	...astro.configs['flat/recommended'],
	...astro.configs['flat/jsx-a11y-recommended'],
	{
		languageOptions: {
			globals: { ...globals.browser, ...globals.node },
		},
		rules: {
			// Project conventions: keep a11y strict, trim noise that is intentional.
			'no-unused-vars': 'off',
			'@typescript-eslint/no-unused-vars': [
				'warn',
				{ argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
			],
			'@typescript-eslint/no-explicit-any': 'off',
			'no-empty': ['warn', { allowEmptyCatch: true }],
			// role="list" on <ul>/<ol> is kept on purpose: Safari/VoiceOver drops
			// list semantics when list-style:none is set, so the explicit role
			// restores them. Still flag other redundant roles (e.g. output/status).
			'astro/jsx-a11y/no-redundant-roles': ['error', { ul: ['list'], ol: ['list'] }],
		},
	},
	{
		// Build/config files legitimately use `// @ts-nocheck` (e.g. loose Vite
		// proxy types in astro.config). Don't flag the directive there.
		files: ['**/*.config.{mjs,js,ts}'],
		rules: { '@typescript-eslint/ban-ts-comment': 'off' },
	},
);

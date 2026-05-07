# Self-hosted fonts

Drop the woff2 files listed below into this folder. The build references them
through `src/styles/base/_typography.scss`. Until the binaries are committed
the page falls back to system stacks (still WCAG-compliant — readability is
preserved).

## Required files (subset to Latin + Latin-Extended)

| File                          | Family           | Weight | Style  | Source                                                                        |
| ----------------------------- | ---------------- | -----: | ------ | ----------------------------------------------------------------------------- |
| `inter-400.woff2`             | Inter            |    400 | normal | <https://rsms.me/inter/font-files/Inter-Regular.woff2?v=4.0>                  |
| `inter-500.woff2`             | Inter            |    500 | normal | <https://rsms.me/inter/font-files/Inter-Medium.woff2?v=4.0>                   |
| `inter-600.woff2`             | Inter            |    600 | normal | <https://rsms.me/inter/font-files/Inter-SemiBold.woff2?v=4.0>                 |
| `inter-700.woff2`             | Inter            |    700 | normal | <https://rsms.me/inter/font-files/Inter-Bold.woff2?v=4.0>                     |
| `caveat-400.woff2`            | Caveat           |    400 | normal | Google Fonts (Open Font License 1.1)                                          |
| `caveat-600.woff2`            | Caveat           |    600 | normal | Google Fonts                                                                  |
| `caveat-700.woff2`            | Caveat           |    700 | normal | Google Fonts                                                                  |
| `caveat-brush-400.woff2`      | Caveat Brush     |    400 | normal | Google Fonts                                                                  |
| `kalam-400.woff2`             | Kalam            |    400 | normal | Google Fonts                                                                  |
| `kalam-700.woff2`             | Kalam            |    700 | normal | Google Fonts                                                                  |
| `special-elite-400.woff2`     | Special Elite    |    400 | normal | Google Fonts                                                                  |
| `architects-daughter-400.woff2` | Architects Daughter | 400 | normal | Google Fonts                                                                  |

## Quick fetch

```bash
cd opposite-osiris/public/fonts
# Inter
for w in 400:Regular 500:Medium 600:SemiBold 700:Bold; do
  curl -fsSL "https://rsms.me/inter/font-files/Inter-${w#*:}.woff2?v=4.0" -o "inter-${w%%:*}.woff2"
done
# The Google-hosted families ship as woff2 inside their CSS responses.
# Use google-webfonts-helper (https://gwfh.mranftl.com/fonts) once,
# unzip the bundle, rename to the file names listed above.
```

After committing the binaries, remove the `<link href="https://fonts.googleapis.com">`
lines and the `https://fonts.googleapis.com` / `https://fonts.gstatic.com`
entries from CSP in `src/layouts/Layout.astro`.

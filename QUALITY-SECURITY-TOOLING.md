# Quality & Security Tooling (Docker-only)

This repo has **no host Node/npm/pnpm** — every check runs inside Docker. This
guide shows how to run each tool and records the current findings.

| Tool | What it catches | Where it runs |
| --- | --- | --- |
| `astro check` | TypeScript / Astro type errors | opposite-osiris container |
| ESLint | JS/TS/Astro correctness + a11y | each app's own scoped lint script |
| `pnpm audit` / `npm audit` | dependency CVEs | per app (matches its package manager) |
| Snyk | dependency + license CVEs (SaaS) | CI only — needs `SNYK_TOKEN` |
| SonarCloud | bugs / smells / hotspots (88k LOC) | `sonar-scanner-cli` → sonarcloud.io |

> Per-app package managers: **pnpm** → opposite-osiris, osionos/app. **npm** →
> baas/sdk, baas/mini-baas-infra/src, mail, calendar.

---

## 1. `astro check` — type-check the website

```sh
docker exec track-binocle-opposite-osiris-1 sh -lc \
  'cd /workspace/apps/opposite-osiris && node scripts/container-only.mjs astro check'
```

It type-checks `.astro` + `.ts` with the project's strict tsconfig. Hints about
`is:inline` apply to inline `<script type="application/ld+json|json">` data
blocks — add `is:inline` to silence (they are data, not processed modules).

**Gotcha:** the strict tsconfig pulls in `@types/node`, so `setTimeout`/
`setInterval` resolve to the Node overload returning `Timeout`, not `number`.
Type timer fields as `ReturnType<typeof setTimeout>` (works in browser **and**
Node), never `number`.

## 2. ESLint — run each app's *own* scoped script

Do **not** run a bare `eslint .` from a repo/app root — it will lint build
output, `vendor/`, and even bundled Python virtualenv `.js`. Use the app script
that carries the right `ignores`:

```sh
# opposite-osiris
docker exec track-binocle-opposite-osiris-1 sh -lc \
  'cd /workspace/apps/opposite-osiris && node scripts/container-only.mjs eslint .'

# osionos/app (its own ignores via the docker-run wrapper)
docker exec track-binocle-osionos-app-1 sh -lc 'cd /app && bash scripts/docker-run.sh lint'
```

## 3. Dependency audit

```sh
# pnpm apps (from the running container, prod deps only)
docker exec track-binocle-opposite-osiris-1 sh -lc \
  'cd /workspace/apps/opposite-osiris && pnpm audit --prod'

# npm apps — no install needed, audit straight from the lockfile:
docker run --rm -v "$PWD/apps/baas/sdk:/a" -w /a node:22-alpine \
  sh -lc 'npm audit --package-lock-only --omit=dev'
```

**Fixing a transitive CVE with pnpm** — use the **selector + caret** form under
`pnpm.overrides` (an open `>=` range or the npm-style top-level `overrides` is
*not* reliably honored here):

```jsonc
// package.json
"pnpm": { "overrides": { "qs@<6.15.2": "^6.15.2" } }
```

Then regenerate the lockfile (mount the **repo root** so `file:` links resolve):

```sh
docker run --rm -v "$PWD:/repo" -w /repo/apps/<app> node:22-alpine sh -lc \
  'corepack enable && corepack prepare pnpm@11.5.1 --activate && \
   pnpm install --lockfile-only && chown 1000:1000 pnpm-lock.yaml'
```

> The repo enforces a **supply-chain policy** (`minimum-release-age`) during
> install; a brand-new patch can be held back, so an override may not rewrite a
> deep transitive until the patch ages in or the upstream pin moves.

## 4. Snyk — CI only

Snyk's CLI needs an account token. There is **no local `SNYK_TOKEN`** (it's a CI
secret used by `.github/workflows/mini-baas-security.yml → sca-snyk`). To run it
locally you would authenticate once:

```sh
# interactive (opens a browser) — not possible headless:
docker run --rm -it -v "$PWD:/p" -w /p snyk/snyk:node snyk auth
# or with a token from snyk.io → Account settings → Auth Token:
docker run --rm -e SNYK_TOKEN=<token> -v "$PWD:/p" -w /p snyk/snyk:node snyk test
```

Until a token is provisioned, **`pnpm/npm audit` + the repo's Semgrep job**
(`make baas-security-scan` / `apps/baas/mini-baas-infra/scripts/security/`)
cover the same SCA/SAST ground locally.

## 5. SonarCloud — full static analysis

Project key **`Univers42_ft_transcendence`** (org `univers42`), token in
`.env.local` as `SONAR_TOK`. Automatic Analysis is **off**, so analyse directly
(no git push needed):

```sh
docker run --rm -e SONAR_TOKEN="$SONAR_TOK" -e SONAR_HOST_URL=https://sonarcloud.io \
  -v "$PWD:/usr/src" sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=Univers42_ft_transcendence -Dsonar.organization=univers42
```

`sonar-project.properties` excludes generated/non-product paths (Docusaurus
`wiki/**`, `**/sandbox/**`, the `apps/prismatica/**` prototype, build output).

---

## Current findings & resolutions (2026-06-05)

| Check | Result |
| --- | --- |
| **astro check** (opposite-osiris) | 6 type errors + 3 hints → **0 / 0 / 0** (timer types → `ReturnType<typeof setTimeout>`; `is:inline` on JSON-LD/data scripts; excluded `eslint.config.mjs` from app type-check) |
| **ESLint** opposite-osiris | **0 errors / 0 warnings** |
| **npm audit** baas/sdk · mini-baas-infra/src · mail · calendar | **0 vulnerabilities** each |
| **pnpm audit** opposite-osiris | 1 moderate — `yaml <2.8.3` via `@astrojs/check → yaml-language-server` (**dev/build-time only**, never parses runtime input). Override declared (`yaml@<2.8.3: ^2.9.0`); held by the supply-chain policy / upstream pin — resolves on next toolchain bump. |
| **pnpm audit** osionos/app | 4 moderate — all `hono <4.12.21` via `@modelcontextprotocol/sdk`. **Fix on the osionos branch** (its own workflow): add `"hono@<4.12.21": "^4.12.21"` to its existing `pnpm.overrides` (same pattern as its `qs` override) and regenerate the lockfile. |
| **SonarCloud** | 0 open issues, 0 hotspots to review (see [[project-sonarcloud-cleanup]] in agent memory) |
| **Snyk** | not run — no local token; covered by audit + Semgrep |

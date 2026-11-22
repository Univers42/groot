# 0076. The app shell CSP is owned by the web image and enforced only after a three-engine sweep

- Status: accepted. devil 2026-11-22: PROCEED-WITH-CONDITIONS D314-1–24. Report-Only (S1) and the edge de-duplication (S2) may proceed under them. Enforce (S3) is held behind D314-13, -16, -17, -18 and -19.
- Date: 2026-11-22
- Deciders: devil (ruling); coordinator (Q1–Q5 under the user's standing go); osionos builder. Issue: Univers42/osionos#314, follow-up #342.
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-314.md`. Evidence: `/mnt/storage/dlesieur/scratch/me-d/REPORT-314.md` and `r314/logs/`.

## Context

- Prod sends `frame-ancestors` twice: once from the app image's nginx and once from the groot edge. The shell has no `script-src` at all, so an injected script runs unhindered.
- In the prod image's built files (`track-binocle/osionos-web:main-0e10ff56-site`), the only `new Function` is jszip's `setImmediate` polyfill, and it is reached only for a string callback. There is no `eval(`. Two inline scripts in `index.html` have static hashes.
- The sweep measured one live eval path that the static read missed: zod 4 probes `new Function` on every boot. It falls back by itself, but under enforce it logs a violation. Fixed with `z.config({ jitless: true })` (`src/app/zodNoEval.ts:8`), imported first in `main.tsx`.
- `script-src 'self'` does not cover same-origin uploads. An object stored on `/storage/v1` as `text/javascript` can be loaded by `<script src>`, and nosniff does not stop that (U1, D314-16). ADR 0074's `sandbox` governs top-level documents only.
- Users reach osionos through the nginx images (:8443 and the beta host). `vercel.json` and `public/_headers` serve no user today.

## Decision

The policy string exists once, in the osionos web image: `docker/services/node/nginx.conf:9-11`, a `map` at http level, referenced as `Content-Security-Policy-Report-Only` by the server block and by every location that declares `add_header` (`:39,51,60,73,83,92`):

```
script-src 'self' 'wasm-unsafe-eval' 'sha256-…' 'sha256-…'; worker-src 'self' blob:; object-src 'none'; base-uri 'none'
```

The enforced header stays `frame-ancestors 'none'` until S3. Rollout is three steps, each in its own window:

1. **S1, osionos:** Report-Only, as above. It rides a normal web promotion (ADR 0043/0046/0067).
2. **S2, groot:** the edges add `frame-ancestors` only when the upstream sent no CSP. It lands only after an image with S1 serves (D314-7).
3. **S3, osionos:** the same string becomes `Content-Security-Policy`. This needs the enforced sweep green on all three engines (D314-13), U1 closed (D314-16), a live read-only check after S1 (D314-17), the D314-19 list, and the user's own go (D314-18).

`connect-src`, `frame-src`, `img-src` and `style-src` are phase 2 (#342). #314 closes on `script-src`, `object-src`, `base-uri` and `worker-src` enforced (Q3).

## Alternatives considered

- **Edge-owned app CSP:** version skew. The web image is promoted alone (ADR 0043), so an edge policy would describe a different build than the one it serves.
- **Nonce + `'strict-dynamic'`:** per-response templating, and a nonce mismatch blanks the app. Hashes are static and enough.
- **`'unsafe-inline'` or `'unsafe-eval'` in `script-src`:** each voids the policy; neither is needed (§Context).
- **Enforce at once:** the sweep found the zod eval only by running. Report-Only is the cheap way to find the next one.

Each rejected option has a `.out-of-scope/` file with the fact that would reopen it.

## Consequences

- No violation sink (Q1). Evidence comes from the sweep only, so field violations stay invisible during Report-Only. Untested surfaces (D314-19): IDE terminal, video rooms, connector pairing, mail and calendar frames, offline boot, voice preview, graph studio in the osionos-only build. On WebKit, also code files and Monaco, the theme json worker, zip export, database wasm, charts and chat.
- `/graph-studio/` carries no CSP (`app.Dockerfile`), as before.
- The zod jitless switch has no performance measurement. Validation uses the interpreter path everywhere.
- U1 closure is (b), an edge MIME rewrite on the storage routes (Q5). It is a denylist: an executable type it does not list passes.
- Until S2 lands, the edges keep sending a second CSP header. Browsers intersect both, so this is redundant rather than unsafe.

## As built (osionos fix/314-app-csp 048c4277d, rebased on develop bea4ab5c0)

- S1 is on the branch: the nginx policy, `scripts/vite/appCsp.ts` (the preview server sends the same string, enforced when `PLAYWRIGHT_CSP=enforce`), `tests/canvas/app-csp.test.ts` (inline-script hashes match the policy), and the Playwright sweep `tests/e2e/bridge-stub/cspSweep.spec.mjs`.
- The sweep needs a production build behind the nginx policy, so it runs only through its own runner, which sets `CSP_MODE` (`playwright.config.ts:75,109`). Without it, CI's dev-server bridge-stub job lists 135 tests in 35 files; with `CSP_MODE=report`, 163 in 36.
- Sweep, retries 0:

  | engine | Report-Only | enforced |
  |---|---|---|
  | Chromium | 159 pass / 2 fail / 7 skip | 158 / 3 / 7 |
  | Firefox | 151 / 10 / 7 | 153 / 8 / 7 |
  | WebKit | 45 / 104 / 19, timed out at 2400 s | same |

  Every failure is a non-CSP spec. The same specs fail with no policy served (`nocsp-*.log`). WebKit is SKIP-grade, not a pass: with no policy it cannot reach six surfaces either. D314-13 is therefore not met.
- groot S2 is on branch `fix/314-edge-csp` (bats red then green, rollback scripts rehearsed with `--network none`). It is held per D314-7.
- Live: nothing changed.

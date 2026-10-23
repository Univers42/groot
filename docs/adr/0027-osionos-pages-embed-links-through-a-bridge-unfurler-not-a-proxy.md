# 0026. osionos pages embed links through a bridge unfurler, not a proxy

- Status: accepted
- Date: 2026-10-19
- Deciders: devil (conditions C1–C23 on 2026-10-18; C24–C30 on 2026-10-19), security reviews of the unfurler
  and the client

## Context

- A URL pasted into an osionos page became a text link. The video block played only direct files, so
  YouTube and TikTok pages never played. Chat framed YouTube and Vimeo without a sandbox and sent every
  hostname to Google's favicon service.
- Notion embeds through Iframely. Iframely resolves a URL on the server, through oEmbed and Open Graph, to
  a player URL. On top of that Notion has preset blocks and a paste menu (URL, Mention, Bookmark, Embed).
  When a site refuses framing, Notion shows a link card.
- A site that sends `X-Frame-Options` or `frame-ancestors` cannot be framed by any web page, because the
  browser enforces it. The only way around it is a proxy that strips the headers.
- The bridge holds the BaaS service-role key. It sits next to Kong, Postgres, the tailnet and Fly's private
  network, so any server-side fetch of a user URL is an SSRF surface.
  - The chat link-preview guard already had holes: it followed redirects, so a public URL could 302 to
    169.254.169.254.
  - Node skips the `lookup` hook for IP-literal hosts. Measured: `http://2130706433/` reached 127.0.0.1.
- A sandboxed frame with `allow-same-origin` can still navigate itself, by script or by a server 302.
  Checking the `src` stops only a frame that *starts* on the app's origin. Concretely: an embed of
  `https://evil.example/r` that redirects to `https://<osionos>/#bridge_token=<attacker token>` boots the
  real SPA inside the frame, on its own origin. The SPA then consumes the handoff, which replaces the
  viewer's account set (login CSRF).
  - Prod Vercel already sent `X-Frame-Options: DENY`.
  - The app image's nginx and groot's `:3001` vhost, which the public Funnel's 8443 proxies to, sent
    neither header.

## Decision

- **Scope.** osionos does what Notion does and no more:
  - provider players and frame-friendly pages render inline;
  - sites that refuse framing render as a link card with an Open button;
  - no header-stripping proxy and no desktop force-embed.
- **The unfurl route.** The bridge gains `POST /api/embed/resolve` (`scripts/bridge-embed.mjs`). It is
  built on one SSRF guard (`scripts/bridge-unfurl-net.mjs` and its `-addr`/`-dns` modules), shared with chat
  link-preview and the automation webhook. The guard:
  - checks IP literals before connecting;
  - resolves names through c-ares;
  - pins the socket to the validated addresses;
  - re-validates every manual redirect, at most 3;
  - allows ports 80 and 443 only;
  - caps decoded bytes;
  - bounds each resolve by one deadline.
  - The route returns parsed metadata only (`EmbedInfo`). oEmbed HTML is never returned, and the parser
    reads only the document head with a linear scan.
- **Known oEmbed endpoints.** YouTube, Vimeo, TikTok and Dailymotion are asked through a fixed endpoint
  first (`scripts/bridge-unfurl-oembed.mjs`), through the same guard, with a fallback to the page.
  - Measured: the YouTube watch page is 1.43 MB, past the 512 KB head cap, so a YouTube bookmark had no
    title. Its endpoint answers in about 1 KB.
  - The endpoint hosts are constants; a lookalike host does not match.
  - The player table (YouTube, Vimeo, TikTok, Twitch, Spotify, Loom, Figma, Maps, Docs, Gist and others,
    ported from drawnosaurus `embed.rs`) stays in the client (`src/shared/lib/embed`).
- **One frame component, one sandbox.** Every third-party frame uses
  `allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms allow-presentation`
  and `referrerpolicy=strict-origin-when-cross-origin`. YouTube refuses to play without a Referer.
- **Permissions by frame kind.**

  | Frame | `allow` | Fullscreen |
  |---|---|---|
  | Provider video and audio players | autoplay, encrypted-media, fullscreen, picture-in-picture, clipboard-write, web-share | yes |
  | Provider rich frames (CodePen, Figma, Maps, Forms and others) | the same list | no |
  | Any other page | picture-in-picture only | no |

  - Rich frames run code or forms written by the page's author. Fullscreen hides the URL bar, which is the
    one spoof a host label cannot counter.
  - Same-origin URLs, and URLs on sibling first-party origins, are never framed.
  - Players mount on click.
- **osionos refuses every framer.** Every response carries `Content-Security-Policy: frame-ancestors 'none'`
  and `X-Frame-Options: DENY`:
  - in every location of the app image's nginx, `location = /index.html` included;
  - at server level on groot's `:3001` vhost, so Kong's routes on the same origin are covered too.

  The client also refuses the handoff when `top !== self`, for hosts that serve the build without headers.
  `'self'` is not used (see Alternatives).
- **Public pages (`/p/<token>`) render embeds statically.** Cards and click-to-play facades only; nothing
  is framed until the reader clicks. A marketplace pane whose launch URL is on the page's own origin cannot
  be opened.
- **Storage.**
  - The `embed` and `bookmark` blocks keep the URL in `content`.
  - The resolved snapshot (`embed`) is untrusted. It is re-validated on decode and again at render.
  - Markdown round-trips through `osiembed` and `osibookmark` fences.
- **Electron** gains `media-src 'self' blob: data: https:`. It throttles `window.open` from a WebContents to
  one `openExternal` every 2 s.

## Conditions (devil)

| | Condition | Proven by |
|---|---|---|
| C1-C3 | IP literals and every resolved address are classified by bytes before connecting (incl. 100.64/10, fdaa::/16, mapped and NAT64) | `tests/bridge/bridge-unfurl-ssrf.test.mjs`: a real 127.0.0.1 listener sees 0 connections |
| C4-C6 | c-ares DNS; 8 resolves in flight; a shared `unfurl:<user>` bucket; one deadline; a decoded-byte cap | `bridge-unfurl-budgets`, `bridge-unfurl-hostile`. A 512 KB hostile page took 151,959 ms before the fix and 26 ms after. |
| C7-C11 | Redirects are manual and re-validated; no credentials; a fixed set of errors; every caller uses the guard; 401 before any fetch | `bridge-unfurl-ssrf`, `bridge-unfurl-routes`, `bridge-unfurl-oembed` |
| C13 | One `EmbedInfo` sample, asserted by both the bridge and the client | `tests/fixtures/embed-info.sample.json` |
| C14-C16 | Every URL is validated at render; the sandbox policies; clamped sizes | `tests/canvas/embed-*.test.ts`, `embed-view-model.test.ts`, e2e `embedBlocks.spec.mjs` |
| C17 | Chat frames only provider URLs derived from the attachment URL | `embed-view-model.test.ts` |
| C18 | Pasting makes no network call | e2e `pasteLinkMenu.spec.mjs` |
| C19 | Codec cap of 64 KB; the URL in `content`; the media snapshot survives the page-file overlay | `page-file-codec.test.ts`, `page-file-media-embed.test.ts`, `markdown-roundtrip.test.ts` |
| C21 | The Electron CSP strings are pinned; the popup throttle | `apps/osionos-electron/test/desktop-guards.test.js` |
| C24 | The frame headers on every app-image response | `curl -sI` over `/`, `/index.html`, `/p/abc`, a deep link and a hashed asset, against `nginx:1.27-alpine` running the conf |
| C25 | The same pair on groot's `:3001` vhost | `public-verify` `frame-headers` check; `public-verify-surfaces.bats`, where a stub missing a header or sending `'self'` reports FAIL |
| C26 | A framed boot consumes no handoff | canvas unit test; the opt-in e2e (a 302 into `/#bridge_token=probe`) |
| C27 | No comment claims that the `src` check makes `allow-same-origin` safe | `rg "safe only because"` returns 0 |
| C28 | A pane on the app's own origin cannot be opened | the `launchPolicy` canvas test |
| C29 | No zero-click frame for a public reader | e2e: a public page with generic, CodePen and YouTube embeds has 0 iframes |
| C30 | Fullscreen only for provider video and audio players | `embed-policy.test.ts`, `link-block-export.test.ts`, `embedBlocks.spec.mjs` |

## Alternatives

- **A header-stripping proxy, or desktop force-embed.** Rejected. Notion does neither. Either would make the
  bridge serve third-party pages on a first-party origin.
- **`frame-ancestors 'self'` / `SAMEORIGIN`.** Rejected. After the redirect, the attacking frame's ancestor
  *is* the osionos origin, so `'self'` lets the SPA boot inside it. A shell that ever has to frame osionos is
  listed explicitly (`.out-of-scope/frame-ancestors-self.md`).
- **Published pages on a separate origin.** Deferred, not rejected. It becomes mandatory if a stored-XSS bug
  turns up in the public renderer, or if uploaded HTML turns out to be served as `text/html` on the app
  origin.
- **Dropping `allow-forms`.** Rejected. While scripts are allowed, the frame can still send credentials with
  `fetch()`.

## Consequences

- **Cards instead of pages.** Google, GitHub, banks and most news sites show a card, not the page, as in
  Notion.
- **Privacy.** Viewers' browsers load third-party players, images and favicons directly, so those sites see
  the viewer's IP.
- **Twitch.** Its players need the `parent` hostname and refuse non-standard ports. They work on 443, not on
  the local `:3001`.
- **Cached frameability.** The flag is read from response headers when the page is resolved and cached for
  24 h. A site that changes its policy shows the stale state until the cache expires.
- **Fullscreen.** Figma, Maps, CodePen and other rich frames lose their fullscreen button.
- **Self-framing.** The default `osionos.desktop` pane can no longer show osionos inside osionos on the same
  origin.
- **Public readers.** Readers of a published page see cards and facades until they click.
- **Rollout.** The Fly bridge must be redeployed for `/api/embed/resolve`. Until then the client falls back
  to the provider table and to hostname cards.
- **Open follow-ups:**
  - F1: the handoff is not bound to the browser that started the login, so a top-level link still swaps the
    account set.
  - F2: uploaded HTML may be served on the app origin through Kong's storage catch-all.

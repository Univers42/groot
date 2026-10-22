# Letting osionos frame itself (`frame-ancestors 'self'`, `SAMEORIGIN`) is out of scope

- Decided: 2026-10-19 · by devil (embeds follow-up ruling, conditions C24–C28, [ADR 0026](../docs/adr/0026-osionos-pages-embed-links-through-a-bridge-unfurler-not-a-proxy.md))
- Holds while: osionos pages frame third-party URLs with `allow-same-origin`, and the SPA acts on a URL on boot
  (the `#bridge_token` handoff)

## The concept

Send `frame-ancestors 'self'` (or `X-Frame-Options: SAMEORIGIN`) instead of `'none'`/`DENY`, so osionos can still
show itself in a pane: the default-installed `osionos.desktop` marketplace app, or a page of the app embedded in
another page.

## Why not

`'self'` does not stop the attack the header is there for.

- A page embed is a cross-origin frame, but the framed page can navigate itself, by script or by a server 302.
  The same-origin check on the embed's `src` sees only the first URL.
- After `https://evil.example/r` redirects to `https://<osionos>/#bridge_token=<attacker token>`, the frame's only
  ancestor is the osionos page holding the embed. `'self'` matches it, the real SPA boots inside the frame on its
  own origin, and the handoff replaces the viewer's account set (login CSRF).
- Only `'none'` / `DENY` refuse that frame. The client guard (no handoff when `top !== self`) is the second layer
  for hosts that serve the build without headers. It is not a reason to relax the header.

## What would have to change

A surface that really needs to frame osionos is named explicitly in `frame-ancestors`, as an origin that is not
osionos itself. Even then, the osionos pages that frame third-party content must sit on a different origin from
the one that is listed. Reopen this only with a devil ruling.

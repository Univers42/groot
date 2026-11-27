# Pinning each service's link env instead of fixing the link mode is out of scope

- Decided: 2026-11-23 · by devil (link-mode ruling, `scratch/link-mode/RULING.md` option C)
- Holds while: the `grobase-link` relay owns the `mini-baas-*` network aliases, so the mode decides routing for every running container

## The concept

Freeze each live service's six link keys in the deploy tree, as `secrets/bridge-link-pin.env` already does for osionos-bridge, so that `make link` only affects dev.

## Why not

- **Pins cover env, not routing.** `make link` recreates the relay with `--force-recreate`. Its aliases (`mini-baas-kong`, `-redis`, `-realtime`) move every container's traffic at once, including Redis, the session store, whatever any env file says.
- **A pin keeps a value that was validated for one mode only.** After a mode change it is silently stale. For example, ssh's empty `REALTIME_PUBLISH_URL` against a direct relay that has no 4000 route.
- **It fixes none of the ssh mode's real hazards:** an unpinned host key, the CRS bypass, and the unauthenticated 4000 route.

## Prior requests

- 2026-11-23 (link-mode ruling, option C). The osionos-bridge pin itself stays as part of option D until LM-10 removes it.

## Reopen when

The relay stops being the shared route for production. For example, production containers reach grobase through their own pinned endpoints rather than `mini-baas-*` aliases.

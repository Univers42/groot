# Track Binocle — desktop launcher (v0)

The all-in-one orchestrator, first iteration: **one click → the whole local
suite runs → osionos opens.** osionos is the orchestrator (its sidebar opens
Mail and Calendar); the lean BaaS (postgres, kong, gotrue, postgrest, redis)
runs underneath. Everything runs on **your** machine.

## Use it

```bash
# add a "Track Binocle" entry to your application menu (one-time)
infrastructure/desktop/track-binocle-launch.sh --install

# or run directly: boots the full suite + opens osionos
infrastructure/desktop/track-binocle-launch.sh

# stop everything
infrastructure/desktop/track-binocle-launch.sh --stop
```

Then launch **Track Binocle** from your app menu. First run generates local
secrets offline (`make bootstrap`) if needed, brings up the Docker suite, waits
for health, and opens `https://localhost:3001`.

## Notes / design

- **HTTPS is preserved** — the suite serves `https://localhost:*` via the local
  TLS proxy (the web/server distribution stays HTTPS by design). The desktop
  HTTP-loopback mode lands with the native Tauri build.
- **Mail/Calendar** run in mock/local mode (no Google OAuth needed); "Connect
  Google" is an opt-in later.
- Requires **Docker** (the suite's engine) — the whole project is Docker-first.

## Next steps (tracked in the plan)

1. **Native Tauri app** — embedded osionos webview, HTTP-loopback, packaged as
   `.AppImage` / `.deb` (no browser, true "click the icon").
2. **No-source download bundle** — build *production* images for Mail/Calendar
   (frontend + bridge; today they are dev-only, source-mounted) so the suite
   runs on a machine without this repo.

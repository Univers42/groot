# osionos desktop (native Tauri app)

The native "click-the-icon" osionos app for Linux. It embeds the osionos editor
in a WebKitGTK window and **orchestrates the local suite** (osionos backend +
Mail + Calendar + lean BaaS) over **HTTP on loopback**, so opening the app brings
the whole thing up. The web/server distribution stays HTTPS — this HTTP-loopback
mode is desktop-only.

This project lives in the monorepo (not the osionos submodule) so the submodule
stays clean; it bundles the osionos `build/` output at build time.

## Build (in a container — no host Rust/Node)

```bash
# 1. build the Tauri build image (Rust + Node + WebKitGTK + AppImage tooling)
docker build -f apps/osionos-desktop/docker/build.Dockerfile -t track-binocle/tauri-build .
# 2. compile the app -> .AppImage / .deb  (see apps/osionos-desktop/build.sh)
docker run --rm -v "$PWD":/work track-binocle/tauri-build apps/osionos-desktop/build.sh
```

## Run (host runtime libs — one-time)

A native GTK/WebKit app needs system libs on the machine it runs on:

```bash
sudo apt install -y libwebkit2gtk-4.1-0 libgtk-3-0 libayatana-appindicator3-1 librsvg2-2
```

Then run the produced `.AppImage` (or `sudo apt install ./*.deb`). Docker must be
installed and running (the app boots the suite via `docker compose`).

## Architecture

- **Shell:** Tauri v2 (Rust) window loading the bundled osionos SPA.
- **Backend:** on launch the shell runs `docker compose` on the desktop
  HTTP-loopback compose; osionos is built with `VITE_API_URL=http://localhost:4000`,
  `VITE_BAAS_URL=http://localhost:8000`, offline mode on.
- **Auth/token:** osionos already uses a Bearer `osionos_v1.*` token (no cookies);
  it persists in the webview store. (OS-keychain storage is a later upgrade.)
- **Next:** runtime backend selector (Local / Cloud / custom URL) for the
  user-choice model; prod Mail/Calendar images for a no-source download.

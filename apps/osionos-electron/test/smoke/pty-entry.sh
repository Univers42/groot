#!/bin/sh
# Runs INSIDE the smoke container. Installs electron+playwright into the cache volume once,
# trusts the dev CA, then runs the local-terminal smoke under xvfb (no sign-in, no password).
set -eu
cd /cache
# The smoke drives the Electron the app ships (package.json pins it); the cache follows that pin.
want="$(node -p "require('/app/package.json').devDependencies.electron")"
have="$(node -p "try { require('/cache/node_modules/electron/package.json').version } catch { '' }")"
if [ "$have" != "$want" ] || [ ! -x node_modules/electron/dist/electron ]; then
	[ -f package.json ] || echo '{"name":"smoke-cache","private":true}' >package.json
	npm install --no-audit --no-fund --no-save "electron@$want" playwright-core@1.49.1 >&2
fi
# npm 11 holds back install scripts it has not been told to allow, electron's binary download included.
[ -x node_modules/electron/dist/electron ] || node node_modules/electron/install.js >&2
mkdir -p "$HOME/.pki/nssdb"
certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password </dev/null >/dev/null 2>&1 || true
certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n osionos-dev -i /ca.pem </dev/null
# xvfb-run hangs after node exits in this image; a fixed display (:77 - host only has X0) is simpler.
Xvfb :77 -screen 0 1440x900x24 -nolisten tcp &
xvfb_pid=$!
trap 'kill $xvfb_pid 2>/dev/null' EXIT # openbox dies with the display
sleep 1
DISPLAY=:77 openbox >/dev/null 2>&1 &
sleep 1
DISPLAY=:77 node /smoke/pty-smoke.mjs

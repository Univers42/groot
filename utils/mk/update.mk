# update.mk — one-shot "apply my source changes" targets, so you never have to
# hand-rebuild osionos after editing it.
#
#   make update_web   Rebuild + restart the osionos WEB app (the static nginx
#                     image). The app bakes its sources at BUILD time, so a plain
#                     `docker compose up` reuses the stale image — this forces the
#                     rebuild. Then hard-reload the app's own URL (the one the
#                     host ports chose, $(OSIONOS_URL)) to see edits.
#
#   make update_app   Rebuild the osionos DESKTOP .deb FIRST, then (re)install it.
#                     `install-app.sh` on its own installs whatever STALE .deb is
#                     already in apps/osionos-electron/dist/ — so we always rebuild
#                     the package before installing. The install step needs root.

OSIONOS_ELECTRON_DIR ?= apps/osionos-electron

##@ Apps
update_web: submodules-pinned ## Rebuild and restart the osionos web app after editing its source
## Covers apps/osionos/app (incl. the graph-engine package). Bakes the app .env (VITE_BAAS_* build
## args) when present; --build is what makes the change actually land (the service has a baked
## image:).
	@touch .env
	@$(WITH_GRAPH_RENDER_SHA) \
	if [ -f "$(OSIONOS_APP_ENV)" ]; then \
		echo "[update_web] rebuilding osionos-app with app env $(OSIONOS_APP_ENV)…"; \
		docker compose --env-file .env --env-file "$(OSIONOS_APP_ENV)" up -d --build osionos-app; \
	else \
		echo "[update_web] rebuilding osionos-app (no app .env; root .env only)…"; \
		docker compose --env-file .env up -d --build osionos-app; \
	fi
	@echo "✅ osionos-app rebuilt + restarted — HARD-RELOAD $(OSIONOS_URL) (Ctrl+Shift+R)."

update_app: ## Rebuild the osionos desktop .deb, then install it (prompts for sudo)
## Usage: make update_app [OSIONOS_DESKTOP_API_URL=<bridge URL> OSIONOS_DESKTOP_BAAS_URL=<grobase URL> OSIONOS_DESKTOP_ENV_FILE=.env.local]
## The three variables aim the app at a data center elsewhere (the tailnet one: bridge
## https://baas.tail10f2ea.ts.net:10000, grobase https://baas.tail10f2ea.ts.net); the app then
## starts no local stack. Unset, it stays wired to this machine's stack.
## Rebuilds the full edition package (apps/osionos-electron/dist/) then installs it. install-app.sh
## alone would install the old artifact, so the rebuild always runs first. The install needs root
## (dpkg + the setuid chrome-sandbox).
	bash $(OSIONOS_ELECTRON_DIR)/build.sh
	sudo bash $(OSIONOS_ELECTRON_DIR)/install-app.sh
	@echo "✅ osionos desktop rebuilt + installed — launch 'osionos' from your app menu."

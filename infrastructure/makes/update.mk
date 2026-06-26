# update.mk — one-shot "apply my source changes" targets, so you never have to
# hand-rebuild osionos after editing it.
#
#   make update_web   Rebuild + restart the osionos WEB app (the static nginx
#                     image). The app bakes its sources at BUILD time, so a plain
#                     `docker compose up` reuses the stale image — this forces the
#                     rebuild. Then hard-reload https://localhost:3001 to see edits.
#
#   make update_app   Rebuild the osionos DESKTOP .deb FIRST, then (re)install it.
#                     `install-app.sh` on its own installs whatever STALE .deb is
#                     already in apps/osionos-electron/dist/ — so we always rebuild
#                     the package before installing. The install step needs root.

OSIONOS_APP_ENV ?= apps/osionos/app/.env
OSIONOS_ELECTRON_DIR ?= apps/osionos-electron

.PHONY: update_web update_app

update_web:
## Rebuild + restart the osionos web app after editing apps/osionos/app (incl. the
## graph-engine package). Bakes the app .env (VITE_BAAS_* build args) when present;
## --build is what makes the change actually land (the service has a baked image:).
	@touch .env
	@if [ -f "$(OSIONOS_APP_ENV)" ]; then \
		echo "[update_web] rebuilding osionos-app with app env $(OSIONOS_APP_ENV)…"; \
		docker compose --env-file .env --env-file "$(OSIONOS_APP_ENV)" up -d --build osionos-app; \
	else \
		echo "[update_web] rebuilding osionos-app (no app .env; root .env only)…"; \
		docker compose --env-file .env up -d --build osionos-app; \
	fi
	@echo "✅ osionos-app rebuilt + restarted — HARD-RELOAD https://localhost:3001 (Ctrl+Shift+R)."

update_app:
## Rebuild the osionos desktop package (full edition -> apps/osionos-electron/dist/)
## then install the freshly built .deb. install-app.sh alone would install the old
## artifact, so the rebuild always runs first. The install needs root (dpkg + the
## setuid chrome-sandbox), so this prompts for sudo.
	bash $(OSIONOS_ELECTRON_DIR)/build.sh
	sudo bash $(OSIONOS_ELECTRON_DIR)/install-app.sh
	@echo "✅ osionos desktop rebuilt + installed — launch 'osionos' from your app menu."

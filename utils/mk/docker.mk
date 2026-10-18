##@ Docker
# Cleaning and inspecting the local Docker environment.
# Safe defaults: volumes are preserved unless explicitly removed, so database data in named
# volumes survives normal cleanup.
fclean: ## Wipe the workspace Docker state; keeps data volumes and build caches
## Usage: make fclean [NUKE_CACHES=1]
## Wipe the WORKSPACE Docker state — root frontends (track-binocle) + grobase backend (mini-baas):
## containers, networks, project images. KEEPS all data volumes AND build caches, so `make all`
## rebuilds warm. Add NUKE_CACHES=1 to also wipe the build caches (cold rebuild).
	@ENVF=""; [ -f ./.env.local ] && ENVF="--env-file ./.env.local"; \
	docker compose $$ENVF down --rmi all --remove-orphans || true
	@$(MAKE) --no-print-directory -C apps/grobase clean NUKE_CACHES=$(NUKE_CACHES)
	@docker image prune -f >/dev/null 2>&1 || true
	@echo "✓ fclean done — data volumes preserved (make ffclean CONFIRM=1 wipes them too). Rebuild: make all"

ffclean: ## DANGER: fclean plus PERMANENT deletion of every data volume; needs CONFIRM=1
## Usage: make ffclean CONFIRM=1 [NUKE_CACHES=1]
## DANGER: fclean + WIPE DATA VOLUMES of both projects (track-binocle_* + mini-baas_*) —
## postgres/mongo/mysql/minio data is PERMANENTLY DELETED. Requires CONFIRM=1.
	@if [ "$(CONFIRM)" != "1" ]; then \
	  echo "ffclean PERMANENTLY DELETES all data volumes (track-binocle_* + mini-baas_*)."; \
	  echo "Refusing without confirmation — re-run: make ffclean CONFIRM=1"; exit 1; fi
	@ENVF=""; [ -f ./.env.local ] && ENVF="--env-file ./.env.local"; \
	docker compose $$ENVF down -v --rmi all --remove-orphans || true
	@$(MAKE) --no-print-directory -C apps/grobase fclean CONFIRM=1 NUKE_CACHES=$(NUKE_CACHES)
	@docker volume ls -q | grep -E '^track-binocle_' | xargs -r docker volume rm >/dev/null 2>&1 || true
	@docker image prune -f >/dev/null 2>&1 || true
	@echo "✓ ffclean done — workspace reset, data volumes wiped. Rebuild from scratch: make all"

docker-clean: ## Remove unused containers, networks and images; volumes only with BOOL=true
## Usage: make docker-clean [BOOL=true]
## Remove all unused containers, networks, images (dangling/unreferenced), and optionally, volumes.
	docker system prune -a --volumes=$(BOOL) -f

docker-rm-all: ## DESTRUCTIVE: remove all containers and images, prune system and cache
## Usage: make docker-rm-all [BOOL=true]
## Remove all containers and images, prune system and builder cache.
	docker ps -aq | sort -u | xargs -r docker rm -f
	@removed=1; while [ "$$removed" = "1" ]; do \
		removed=0; \
		for image_id in $$(docker images -aq 2>/dev/null); do \
			if docker rmi -f "$$image_id" >/dev/null 2>&1; then \
				removed=1; \
			fi; \
		done; \
	done; true
	docker system prune -a --volumes=$(BOOL) -f
	@env -u BUILDX_BUILDER docker buildx use default >/dev/null 2>&1 || true
	@env -u BUILDX_BUILDER docker builder prune -a -f || true

docker_verify: ## Show containers, images, volumes, networks and disk usage
	docker ps -a
	docker images -a
	docker volume ls
	docker network ls
	docker system df -v

docker_reclaim_cache: ## Remove the BuildKit/buildx cache only
	@env -u BUILDX_BUILDER docker buildx use default >/dev/null 2>&1 || true
	@env -u BUILDX_BUILDER docker builder prune -a -f || true

docker_reclaim_dangling: ## Remove dangling volumes (no container reference); keeps live data
## Free dangling volumes (build caches, orphaned node_modules, Rust/Go targets). SAFE: only removes
## volumes with no container reference — never touches live DB or service data.
	@echo "=== dangling volumes before ==="
	@docker volume ls -f dangling=true --format '{{.Name}}' | wc -l | xargs -I{} echo "{} dangling volumes"
	@docker volume ls -f dangling=true --format '{{.Name}}' | xargs -r docker volume rm 2>/dev/null | wc -l | xargs -I{} echo "{} volumes removed" || true
	@env -u BUILDX_BUILDER docker buildx use default >/dev/null 2>&1 || true
	@env -u BUILDX_BUILDER docker builder prune -a -f 2>/dev/null | tail -1 || true
	@echo "=== /home after ==="; df -h /home | tail -1

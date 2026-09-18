## == Docker Environment Management ==

## These targets help fully clean and inspect our local Docker environment.
## SAFE DEFAULTS:
## - Volumes are preserved unless explicitly removed.
## - Database data stored in named volumes will survive normal cleanup.

fclean:
## Wipe the WORKSPACE Docker state — root frontends (track-binocle) + grobase backend (mini-baas):
## containers, networks, project images. KEEPS all data volumes AND build caches, so `make all`
## rebuilds warm. Add NUKE_CACHES=1 to also wipe the build caches (cold rebuild).
	@ENVF=""; [ -f ./.env.local ] && ENVF="--env-file ./.env.local"; \
	docker compose $$ENVF down --rmi all --remove-orphans || true
	@$(MAKE) --no-print-directory -C apps/grobase clean NUKE_CACHES=$(NUKE_CACHES)
	@docker image prune -f >/dev/null 2>&1 || true
	@echo "✓ fclean done — data volumes preserved (make ffclean CONFIRM=1 wipes them too). Rebuild: make all"

ffclean:
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

docker-clean:
## Remove all unused containers, networks, images (dangling/unreferenced), and optionally, volumes.
	docker system prune -a --volumes=$(BOOL) -f

docker-rm-all:
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

docker_verify:
## Show all containers (running and stopped), images, volumes, networks, and disk usage.
	docker ps -a
	docker images -a
	docker volume ls
	docker network ls
	docker system df -v

docker_reclaim_cache:
## Remove BuildKit/buildx cache only.
	@env -u BUILDX_BUILDER docker buildx use default >/dev/null 2>&1 || true
	@env -u BUILDX_BUILDER docker builder prune -a -f || true

docker_reclaim_dangling:
## Free dangling volumes (build caches, orphaned node_modules, Rust/Go targets).
## SAFE: only removes volumes with no container reference — never touches live DB or service data.
	@echo "=== dangling volumes before ==="
	@docker volume ls -f dangling=true --format '{{.Name}}' | wc -l | xargs -I{} echo "{} dangling volumes"
	@docker volume ls -f dangling=true --format '{{.Name}}' | xargs -r docker volume rm 2>&1 | grep -c removed | xargs -I{} echo "{} volumes removed" || true
	@env -u BUILDX_BUILDER docker buildx use default >/dev/null 2>&1 || true
	@env -u BUILDX_BUILDER docker builder prune -a -f 2>/dev/null | tail -1 || true
	@echo "=== /home after ==="; df -h /home | tail -1

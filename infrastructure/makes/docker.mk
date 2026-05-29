## == Docker Environment Management ==

## These targets help fully clean and inspect our local Docker environment.
## SAFE DEFAULTS:
## - Volumes are preserved unless explicitly removed.
## - Database data stored in named volumes will survive normal cleanup.

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

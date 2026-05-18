# Docker build and image prefetch targets.
buildx-setup:
## Ensure a BuildKit docker-container builder is available for parallel bake builds.
	@set -eu; \
	if docker buildx inspect '$(BUILDX_BUILDER)' >/dev/null 2>&1; then \
		docker buildx use '$(BUILDX_BUILDER)' >/dev/null; \
	else \
		docker buildx create --name '$(BUILDX_BUILDER)' --driver docker-container --driver-opt image='$(BUILDX_IMAGE)' --use >/dev/null; \
	fi; \
	if ! timeout --kill-after='$(BUILDX_BOOTSTRAP_KILL_AFTER)s' '$(BUILDX_BOOTSTRAP_TIMEOUT)s' docker buildx inspect --bootstrap '$(BUILDX_BUILDER)' >/dev/null; then \
		echo '[docker] recreating unresponsive buildx builder $(BUILDX_BUILDER)'; \
		docker buildx rm -f '$(BUILDX_BUILDER)' >/dev/null 2>&1 || true; \
		docker buildx create --name '$(BUILDX_BUILDER)' --driver docker-container --driver-opt image='$(BUILDX_IMAGE)' --use >/dev/null; \
		timeout --kill-after='$(BUILDX_BOOTSTRAP_KILL_AFTER)s' '$(BUILDX_BOOTSTRAP_TIMEOUT)s' docker buildx inspect --bootstrap '$(BUILDX_BUILDER)' >/dev/null; \
	fi

compose-build: buildx-setup
## Build local Compose images in parallel with BuildKit bake and optional registry cache.
	@set -eu; \
	cache_flags=''; \
	if [[ -n '$(REGISTRY_CACHE_PREFIX)' ]]; then \
		echo '[docker] using registry build cache $(REGISTRY_CACHE_PREFIX)'; \
		for target in $(BAKE_TARGETS); do \
			cache_ref='$(REGISTRY_CACHE_PREFIX)'"/$$target"; \
			cache_flags="$$cache_flags --set $$target.cache-from=type=registry,ref=$$cache_ref"; \
			cache_flags="$$cache_flags --set $$target.cache-to=type=registry,ref=$$cache_ref,mode=max"; \
		done; \
	fi; \
	docker buildx bake --builder '$(BUILDX_BUILDER)' --file '$(BAKE_FILE)' --load $$cache_flags '$(BAKE_GROUP)'

docker-prefetch-images:
## Pull required public images from resilient mirrors before Compose builds.
	@set -eu; \
	jobs='$(DOCKER_PREFETCH_JOBS)'; \
	scope='$(DOCKER_PREFETCH_SCOPE)'; \
	case "$$jobs" in ''|*[!0-9]*) echo '[docker] DOCKER_PREFETCH_JOBS must be a positive integer'; exit 1;; esac; \
	case "$$scope" in all|vault) ;; *) echo '[docker] DOCKER_PREFETCH_SCOPE must be all or vault'; exit 1;; esac; \
	if [ "$$jobs" -lt 1 ]; then jobs=1; fi; \
	echo "[docker] prefetching $$scope images with up to $$jobs concurrent pulls"; \
	pull_image() { \
		target="$$1"; shift; \
		if docker image inspect "$$target" >/dev/null 2>&1; then echo "[docker] using cached $$target"; return 0; fi; \
		refs="$$* $$target"; \
		for ref in $$refs; do \
			attempt=1; \
			while [ "$$attempt" -le '$(DOCKER_PULL_ATTEMPTS)' ]; do \
				echo "[docker] pulling $$ref for $$target (attempt $$attempt/$(DOCKER_PULL_ATTEMPTS), timeout $(DOCKER_PULL_TIMEOUT)s)"; \
				if timeout --kill-after='$(DOCKER_PULL_KILL_AFTER)s' '$(DOCKER_PULL_TIMEOUT)s' docker pull -q "$$ref" >/dev/null; then \
					if [ "$$ref" != "$$target" ]; then docker tag "$$ref" "$$target" >/dev/null; fi; \
					echo "[docker] ready $$target"; \
					return 0; \
				fi; \
				attempt=$$((attempt + 1)); \
			done; \
		done; \
		echo "[docker] failed to pull $$target"; return 1; \
	}; \
	failed=0; \
	wait_for_pull() { \
		set +e; wait -n; status="$$?"; set -e; \
		if [ "$$status" -ne 0 ] && [ "$$status" -ne 127 ]; then failed=1; fi; \
	}; \
	start_pull() { \
		pull_image "$$@" & \
		while [ "$$(jobs -pr | wc -l)" -ge "$$jobs" ]; do wait_for_pull; done; \
	}; \
	start_pull public.ecr.aws/docker/library/node:22-alpine; \
	start_pull public.ecr.aws/docker/library/nginx:1.27-alpine; \
	start_pull docker/dockerfile:1; \
	start_pull docker/dockerfile:1.7; \
	start_pull public.ecr.aws/hashicorp/vault:1.16; \
	if [[ "$$scope" == 'all' ]]; then \
		start_pull public.ecr.aws/docker/library/node:22-bookworm-slim; \
		start_pull public.ecr.aws/docker/library/postgres:16-alpine; \
		start_pull public.ecr.aws/docker/library/redis:7-alpine; \
		start_pull '$(MAILPIT_IMAGE)'; \
		start_pull public.ecr.aws/docker/library/kong:3.8; \
		start_pull mirror.gcr.io/postgrest/postgrest:v12.2.3; \
		start_pull public.ecr.aws/supabase/gotrue:v2.188.1; \
		start_pull public.ecr.aws/supabase/postgres-meta:v0.91.0; \
	fi; \
	while [ "$$(jobs -p | wc -l)" -gt 0 ]; do wait_for_pull; done; \
	if [ "$$failed" -ne 0 ]; then echo '[docker] one or more image pulls failed'; exit 1; fi
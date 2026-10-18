# Docker build and image prefetch targets.
##@ Docker
buildx-setup: ## Ensure a BuildKit docker-container builder exists for parallel bake builds
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

compose-build: buildx-setup ## Build the local Compose images in parallel with BuildKit bake
## Usage: make compose-build [BAKE_GROUP=<group>] [BAKE_TARGETS='<targets>'] [REGISTRY_CACHE_PREFIX=<ref>]
## Optional registry build cache when REGISTRY_CACHE_PREFIX is set.
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

docker-prefetch-images: ## Pre-pull public base images from resilient mirrors before builds
## Usage: make docker-prefetch-images [DOCKER_PREFETCH_SCOPE=all|frontends] [DOCKER_PREFETCH_JOBS=<n>]
## Pull required public images from resilient mirrors before Compose builds. Scope `frontends` is
## only the bases of the images frontends-up builds (make all); `all` adds docker/dockerfile:1.
	@set -eu; \
	jobs='$(DOCKER_PREFETCH_JOBS)'; \
	scope='$(DOCKER_PREFETCH_SCOPE)'; \
	case "$$jobs" in ''|*[!0-9]*) echo '[docker] DOCKER_PREFETCH_JOBS must be a positive integer'; exit 1;; esac; \
	case "$$scope" in all|frontends) ;; *) echo '[docker] DOCKER_PREFETCH_SCOPE must be all or frontends'; exit 1;; esac; \
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
	start_pull public.ecr.aws/docker/library/node:22-alpine node:22-alpine; \
	start_pull public.ecr.aws/docker/library/nginx:1.27-alpine nginx:1.27-alpine; \
	start_pull docker/dockerfile:1.7; \
	if [[ "$$scope" != 'frontends' ]]; then \
		start_pull docker/dockerfile:1; \
	fi; \
	start_pull public.ecr.aws/docker/library/node:22-bookworm-slim node:22-bookworm-slim; \
	start_pull "$$(sed -n 's/^ARG GRAPH_STUDIO_PACK=//p' infrastructure/docker/osionos/app.Dockerfile)"; \
	while [ "$$(jobs -p | wc -l)" -gt 0 ]; do wait_for_pull; done; \
	if [ "$$failed" -ne 0 ]; then echo '[docker] some prefetch pulls failed (transient registry rate-limit?) — continuing; the build/up pulls these on demand' >&2; fi

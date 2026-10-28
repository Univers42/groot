# hydrawn — the osionos whiteboard (apps/hydrawn), one static service: hydrawn-web.
#
# Its boards are not here: hydrawn's osionos build saves through the osionos bridge into
# grobase Mongo, so there is no API, database or relay to start. The build shape is a
# nested `engine` submodule (Univers42/draw-engine) compiled to engine/pkg by a
# profile-gated wasm container, and an image that only checks that pkg EXISTS. A stale
# engine builds clean and is silently wrong, so the SHA assert runs before the wasm
# step, never after.

HYDRAWN_DIR := apps/hydrawn
HYDRAWN_SERVICES := hydrawn-web
# Cap for predictability on a many-core host: measured cold on a 6-core / 8 GB VM
# (2026-09-28), 3 jobs = 62s vs 60s uncapped; ~900 MB of the peak is the fixed rustc/LLVM set.
HYDRAWN_CARGO_JOBS ?= 4
HYDRAWN_ENGINE_SHA = $(shell git -C $(HYDRAWN_DIR) ls-tree HEAD engine | awk '{print $$3}')
# Rootful daemon: run as the invoking user so engine/pkg is not root-owned on the bind
# mount. Rootless: the container's root already is that user, where --user fails with "cannot setuid to unmapped uid" (DOCKER_ROOTLESS, common.mk).
HYDRAWN_RUN_USER = $(if $(DOCKER_ROOTLESS),,--user $(shell id -u):$(shell id -g))

##@ Apps
hydrawn-assert-engine: ## Fail if hydrawn's nested engine submodule is not at the commit hydrawn pins
	@expected='$(HYDRAWN_ENGINE_SHA)'; \
	actual="$$(git -C $(HYDRAWN_DIR)/engine rev-parse HEAD 2>/dev/null)"; \
	if [ -z "$$expected" ]; then \
		echo "[hydrawn] cannot read the pinned engine SHA — is $(HYDRAWN_DIR) initialised?" >&2; exit 1; fi; \
	if [ "$$expected" != "$$actual" ]; then \
		echo "[hydrawn] engine submodule MISMATCH — refusing to build a wrong wasm artifact." >&2; \
		echo "  expected (pinned by hydrawn): $$expected" >&2; \
		echo "  actual   (checked out):       $${actual:-<none>}" >&2; \
		echo "  fix: git -C $(HYDRAWN_DIR) submodule update --init --recursive" >&2; \
		exit 1; fi; \
	echo "[hydrawn] engine at $$expected — ok"

hydrawn-wasm: hydrawn-assert-engine ## Build apps/hydrawn/engine/pkg, the wasm artifact hydrawn-web requires
	docker compose --profile hydrawn build hydrawn-wasm
	docker compose --profile hydrawn run --rm --no-deps \
		-e CARGO_BUILD_JOBS=$(HYDRAWN_CARGO_JOBS) \
		$(HYDRAWN_RUN_USER) hydrawn-wasm

hydrawn-up: hydrawn-wasm ## Build and start hydrawn-web (wasm first)
## Named services only: this compose project is shared with the live stack.
	HYDRAWN_APP_SHA="$$(git -C $(HYDRAWN_DIR) rev-parse HEAD)" HYDRAWN_ENGINE_SHA='$(HYDRAWN_ENGINE_SHA)' \
		docker compose build $(HYDRAWN_SERVICES)
	docker compose up -d --no-build $(HYDRAWN_SERVICES)

hydrawn-down: ## Stop hydrawn-web (it holds no data)
	docker compose stop $(HYDRAWN_SERVICES)

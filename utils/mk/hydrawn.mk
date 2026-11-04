# hydrawn — opt-in collaborative whiteboard, profile-gated (`hydrawn`).
#
# Mirrors mail.mk, with one addition it cannot skip: the engine SHA assert. hydrawn
# carries a NESTED submodule (`engine` -> Univers42/draw-engine). The wasm artifact is built
# from whatever `engine` is checked out, and `docker/web.Dockerfile:26` only checks that
# engine/pkg EXISTS — not that it is current. A stale engine therefore produces an image that
# builds clean and is silently wrong. The assert runs before the wasm step, never after.
#
# `make all` DOES reach this now: the Whiteboard ships on by default, so the five runtime
# services joined ROOT_FRONTENDS (grobase.mk) and `frontends-up` depends on the wasm target
# below. Only hydrawn-wasm is still profile-gated — see the compose comment on it.

HYDRAWN_DIR := apps/hydrawn
HYDRAWN_SERVICES := hydrawn-mongo hydrawn-api hydrawn-realtime \
                         hydrawn-web hydrawn-gateway
# Cargo jobs for the wasm build. Measured cold on a 6-core / 8 GB VM (2026-09-28, with the
# full stack already up): 3 jobs = 62s and +917 MB over baseline, unconstrained (6) = 60s
# and +950 MB. Parallelism is NOT the memory driver here — ~900 MB of it is the fixed
# rustc/LLVM working set for the one big crate, and the two crates build sequentially. So
# this cap exists for PREDICTABILITY on a many-core host (where cargo would otherwise pick
# nproc), not to rescue this one; 4 keeps the peak flat for ~2s over uncapped.
HYDRAWN_CARGO_JOBS ?= $(or $(DRAWNOSAURUS_CARGO_JOBS),4)
# The engine commit that hydrawn' pinned SHA expects. Read from the superproject index,
# so bumping the submodule pointer updates this automatically rather than drifting.
HYDRAWN_ENGINE_SHA = $(shell git -C $(HYDRAWN_DIR) ls-tree HEAD engine | awk '{print $$3}')

##@ Apps
hydrawn-assert-engine: ## Fail if the nested engine submodule is not at the commit hydrawn pins
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

# Who cargo runs as inside hydrawn-wasm. The artifact lands on a bind mount, so on a
# ROOTFUL daemon the container must run as the invoking user, else engine/pkg comes out
# root-owned on the host and the next build cannot overwrite it. On a ROOTLESS daemon the
# container's root already IS the invoking user (the daemon runs as them), and the host
# uid/gid pair is unmapped inside its user namespace: --user there fails the run with
# "cannot setuid to unmapped uid" (DOCKER_ROOTLESS, common.mk).
HYDRAWN_RUN_USER = $(if $(DOCKER_ROOTLESS),,--user $(shell id -u):$(shell id -g))

hydrawn-wasm: hydrawn-assert-engine ## Build engine/pkg, the Rust->wasm artifact web.Dockerfile requires
## Depends on the assert. CARGO_BUILD_JOBS is passed with -e: nice/ionice on the compose CLI do NOT
## reach cargo, which runs under dockerd, so the job cap is the only control that actually lands.
	docker compose --profile hydrawn build hydrawn-wasm
	docker compose --profile hydrawn run --rm --no-deps \
		-e CARGO_BUILD_JOBS=$(HYDRAWN_CARGO_JOBS) \
		$(HYDRAWN_RUN_USER) hydrawn-wasm

hydrawn-up: hydrawn-wasm ## Start hydrawn (wasm first, then images)
## Services are named explicitly: this compose project is shared with the live stack, so a
## service-less up would reconcile everything.
	docker compose --profile hydrawn build $(HYDRAWN_SERVICES)
	docker compose --profile hydrawn up -d --no-build $(HYDRAWN_SERVICES)

hydrawn-logs: ## Follow hydrawn logs
	docker compose --profile hydrawn logs -f $(HYDRAWN_SERVICES)

hydrawn-down: ## Stop hydrawn (never -v)
## The board data volume outlives a restart.
	docker compose --profile hydrawn stop $(HYDRAWN_SERVICES)

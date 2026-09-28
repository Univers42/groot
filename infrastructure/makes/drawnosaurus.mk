# drawnosaurus — opt-in collaborative whiteboard, profile-gated (`drawnosaurus`).
#
# Mirrors mail.mk, with one addition it cannot skip: the engine SHA assert. drawnosaurus
# carries a NESTED submodule (`engine` -> Univers42/draw-engine). The wasm artifact is built
# from whatever `engine` is checked out, and `docker/web.Dockerfile:26` only checks that
# engine/pkg EXISTS — not that it is current. A stale engine therefore produces an image that
# builds clean and is silently wrong. The assert runs before the wasm step, never after.
#
# Nothing here is reached by `make all`: every service carries `profiles: [drawnosaurus]`.

DRAWNOSAURUS_DIR := apps/drawnosaurus
DRAWNOSAURUS_SERVICES := drawnosaurus-mongo drawnosaurus-api drawnosaurus-realtime \
                         drawnosaurus-web drawnosaurus-gateway
# The engine commit that drawnosaurus' pinned SHA expects. Read from the superproject index,
# so bumping the submodule pointer updates this automatically rather than drifting.
DRAWNOSAURUS_ENGINE_SHA = $(shell git -C $(DRAWNOSAURUS_DIR) ls-tree HEAD engine | awk '{print $$3}')

drawnosaurus-assert-engine:
## Fail loudly if the nested engine submodule is not at the commit drawnosaurus pins.
	@expected='$(DRAWNOSAURUS_ENGINE_SHA)'; \
	actual="$$(git -C $(DRAWNOSAURUS_DIR)/engine rev-parse HEAD 2>/dev/null)"; \
	if [ -z "$$expected" ]; then \
		echo "[drawnosaurus] cannot read the pinned engine SHA — is $(DRAWNOSAURUS_DIR) initialised?" >&2; exit 1; fi; \
	if [ "$$expected" != "$$actual" ]; then \
		echo "[drawnosaurus] engine submodule MISMATCH — refusing to build a wrong wasm artifact." >&2; \
		echo "  expected (pinned by drawnosaurus): $$expected" >&2; \
		echo "  actual   (checked out):            $${actual:-<none>}" >&2; \
		echo "  fix: git -C $(DRAWNOSAURUS_DIR) submodule update --init --recursive" >&2; \
		exit 1; fi; \
	echo "[drawnosaurus] engine at $$expected — ok"

drawnosaurus-wasm: drawnosaurus-assert-engine
## Build engine/pkg (the Rust->wasm artifact web.Dockerfile requires). Depends on the assert.
## --user: this daemon is rootful, and the artifact lands on a bind mount — without it
## engine/pkg is root-owned on the host and the next build cannot overwrite it.
	docker compose --profile drawnosaurus build drawnosaurus-wasm
	docker compose --profile drawnosaurus run --rm --no-deps \
		--user "$(shell id -u):$(shell id -g)" drawnosaurus-wasm

drawnosaurus-up: drawnosaurus-wasm
## Start drawnosaurus (wasm first, then images). Services are named explicitly: this compose
## project is shared with the live stack, so a service-less up would reconcile everything.
	docker compose --profile drawnosaurus build $(DRAWNOSAURUS_SERVICES)
	docker compose --profile drawnosaurus up -d --no-build $(DRAWNOSAURUS_SERVICES)

drawnosaurus-logs:
## Follow drawnosaurus logs.
	docker compose --profile drawnosaurus logs -f $(DRAWNOSAURUS_SERVICES)

drawnosaurus-down:
## Stop drawnosaurus. Never -v: the board data volume outlives a restart.
	docker compose --profile drawnosaurus stop $(DRAWNOSAURUS_SERVICES)

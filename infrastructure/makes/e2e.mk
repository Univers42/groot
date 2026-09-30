# End-to-end smoke of the defense path (tests/e2e): Playwright in its pinned container,
# driving the RUNNING stack. It never starts anything — a down stack fails fast instead.

# healthcheck with no retries: the stock CURL_HEALTH retries 30x2s per URL, which is a
# minute of silence before saying the stack is down.
E2E_CURL_HEALTH := curl --cacert $(LOCAL_CA_CERT) -m 5 -fsS

e2e-preflight:
## Fail fast with a clear message if the live stack is not up (reuses `make healthcheck`).
	@log="$$(mktemp)"; \
	if ! $(MAKE) --no-print-directory healthcheck CURL_HEALTH='$(E2E_CURL_HEALTH)' >"$$log" 2>&1; then \
		tail -n 5 "$$log" >&2; rm -f "$$log"; \
		echo '[e2e] the stack is not up (make healthcheck failed above) — start it with: make all' >&2; \
		exit 1; \
	fi; \
	rm -f "$$log"; echo '[e2e] stack healthy'

e2e: e2e-preflight
## Run the Docker-first e2e smoke (DW3/DW8/DW9/DW10) against the live stack. Leaves e2e- boards: follow with make e2e-clean.
	bash tests/e2e/run.sh

e2e-clean:
## Soft-delete every drawnosaurus board titled e2e-* via the API container; refuses if any title only nearly matches.
	@api="$$(docker compose ps -q drawnosaurus-api)"; \
	if [ -z "$$api" ]; then echo '[e2e-clean] drawnosaurus-api is not running' >&2; exit 1; fi; \
	docker exec -i "$$api" node --input-type=module - $(if $(DRY_RUN),--dry-run) < tests/e2e/clean-boards.mjs

.PHONY: e2e e2e-preflight e2e-clean

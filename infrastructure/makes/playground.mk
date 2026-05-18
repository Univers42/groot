# Playground simulation targets.
playground: healthcheck playground-preview
## Run the Docker Playwright user flow and app-service integration simulation.
	$(MAKE) compose-build BAKE_GROUP=playground BAKE_TARGETS='playground-simulation'
	docker compose --profile testing run --rm playground-simulation
	$(MAKE) showcase

playground-preview:
## Open the VS Code simulation viewer for Docker Playwright results.
	@printf '\nSimulation preview: Docker Playwright will create a throwaway account and bridge it into osionos.\n'
	@printf 'Opening the VS Code simulation viewer: %s\n' '$(PLAYGROUND_VIEWER_URL)'
	@if [ -x '$(VSCODE_CLI)' ]; then \
		'$(VSCODE_CLI)' --reuse-window '$(PLAYGROUND_VIEWER_URL)' >/dev/null 2>&1 || printf 'Open this URL in VS Code Simple Browser: %s\n' '$(PLAYGROUND_VIEWER_URL)'; \
	else \
		printf 'Open this URL in VS Code Simple Browser: %s\n' '$(PLAYGROUND_VIEWER_URL)'; \
	fi
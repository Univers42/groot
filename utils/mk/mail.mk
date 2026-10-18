mail-up: docker-prefetch-images
## Start osionos Mail and the Gmail bridge with Docker Compose.
	$(MAKE) compose-build BAKE_GROUP=mail BAKE_TARGETS='mail'
	docker compose up -d --no-build --pull never mail mail-bridge

mail-logs:
## Follow osionos Mail and Gmail bridge logs.
	docker compose logs -f mail mail-bridge

mail-down:
## Stop osionos Mail and the Gmail bridge containers.
	docker compose stop mail mail-bridge

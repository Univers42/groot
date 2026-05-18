# Repository synchronization targets.
pulls:
## Fetch and pull the root repo plus every recursive submodule using configured upstreams.
	@set -eu; \
	echo '[pulls] root'; \
	git fetch --all --prune; \
	if git symbolic-ref --short -q HEAD >/dev/null && git rev-parse --verify --quiet '@{u}' >/dev/null; then \
		git pull --rebase --autostash; \
	else \
		echo '[pulls] root has no upstream branch; fetched only'; \
	fi; \
	git submodule sync --recursive; \
	git submodule update --init --recursive; \
	git submodule foreach --recursive ' \
		set -eu; \
		branch=$$(git symbolic-ref --short -q HEAD || true); \
		echo "[pulls] $${displaypath} ($${branch:-detached})"; \
		git fetch --all --prune; \
		if [ -n "$$branch" ] && git rev-parse --verify --quiet "@{u}" >/dev/null; then \
			git pull --rebase --autostash; \
		else \
			echo "[pulls] $${displaypath} has no upstream branch; fetched only"; \
		fi \
	'; \
	git submodule update --init --recursive --checkout

pushes:
## Add, commit, and push the root repo plus every recursive submodule. Use GIT_COMMIT_MESSAGE="...".
	@set -eu; \
	git submodule sync --recursive; \
	git submodule update --init --recursive; \
	repos="$$(git submodule foreach --quiet --recursive 'printf "%s\n" "$$displaypath"' | awk '{ print length, $$0 }' | sort -rn | cut -d' ' -f2-)"; \
	printf '%s\n.\n' "$$repos" | while IFS= read -r repo; do \
		[ -n "$$repo" ] || continue; \
		if ! git -C "$$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then continue; fi; \
		branch="$$(git -C "$$repo" symbolic-ref --short -q HEAD || true)"; \
		if [ -z "$$branch" ]; then echo "[pushes] $$repo is detached; skipping push"; continue; fi; \
		echo "[pushes] $$repo ($$branch)"; \
		git -C "$$repo" add -A; \
		if ! git -C "$$repo" diff --cached --quiet; then \
			git -C "$$repo" commit -m '$(GIT_COMMIT_MESSAGE)'; \
		else \
			echo "[pushes] $$repo has no staged changes"; \
		fi; \
		if git -C "$$repo" rev-parse --verify --quiet '@{u}' >/dev/null; then \
			git -C "$$repo" push; \
		else \
			git -C "$$repo" push -u '$(GIT_PUSH_REMOTE)' "$$branch"; \
		fi; \
	done
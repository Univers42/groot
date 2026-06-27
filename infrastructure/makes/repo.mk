# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    repo.mk                                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 22:05:59 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 22:06:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Repository synchronization targets.

# vault42 (zero-knowledge) config — the ONLY secrets store (HashiCorp Vault is retired).
VAULT42_PROJECT ?= transcendence
CTL_IMAGE       ?= docker.io/dlesieur/42ctl:latest
CTL_CFG_DIR     ?= $(HOME)/.config/42ctl

syncro-submodule:
## Force EVERY submodule onto its stable branch at latest (fix detached HEADs, ff-pull) so a fresh start never builds the wrong image. Dirty submodules are skipped (never clobbered). Run `make all` after to rebuild.
	@set -eu; \
	command -v git >/dev/null || { echo '[syncro] git not found' >&2; exit 1; }; \
	echo '[syncro] sync submodule URLs from .gitmodules'; \
	git submodule sync --recursive >/dev/null; \
	echo '[syncro] init + checkout all submodules at their recorded SHAs'; \
	git submodule update --init --recursive; \
	echo '[syncro] put each submodule on a real branch at latest stable'; \
	git submodule foreach --recursive ' \
		set -eu; \
		if ! (git diff --quiet && git diff --cached --quiet) 2>/dev/null; then \
			echo "  ! $$displaypath has local changes — skipping (commit/stash first)"; exit 0; \
		fi; \
		cur=$$(git symbolic-ref --short -q HEAD || true); \
		if [ -n "$$cur" ]; then \
			branch="$$cur"; \
		else \
			decl=$$(git config -f "$$toplevel/.gitmodules" --get "submodule.$$name.branch" 2>/dev/null || true); \
			def=$$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed "s@^origin/@@" || true); \
			branch=$${decl:-$${def:-main}}; \
			git fetch --quiet --prune origin || true; \
			git checkout -B "$$branch" "origin/$$branch"; \
		fi; \
		git fetch --quiet --prune origin || true; \
		git pull --quiet --ff-only origin "$$branch" 2>/dev/null \
			|| echo "  ! $$displaypath: not ff-only (diverged) — left at $$(git rev-parse --short HEAD)"; \
		printf "  = %-28s %s (%s)\n" "$$displaypath" "$$(git rev-parse --short HEAD)" "$$branch"; \
	'; \
	echo '[syncro] verify nothing is left detached…'; \
	bad=$$(git submodule foreach --quiet --recursive 'git symbolic-ref -q HEAD >/dev/null 2>&1 || printf "%s " "$$displaypath"' || true); \
	if [ -n "$$bad" ]; then echo "[syncro] STILL DETACHED (likely dirty/diverged): $$bad" >&2; fi; \
	echo '[syncro] done. Now: make all   (rebuilds frontends from the synced source)'

vault42-push-all:
## vault42: push the WHOLE monorepo *.env*/*.secrets tree (root + every submodule) to the remote ZK vault, encrypted on this machine. Passphrase read hidden. NOTE: agents are blocked from sending secrets off-box — run this yourself.
	@REPO_DIR="$(CURDIR)" CTL_IMAGE="$(CTL_IMAGE)" CTL_CFG_DIR="$(CTL_CFG_DIR)" VAULT_ENV_PROJECT="$(VAULT42_PROJECT)" \
		sh apps/grobase/scripts/vault/ctl-env.sh push

vault42-pull-all:
## vault42: restore the WHOLE monorepo *.env* tree from the remote ZK vault — DRY-RUN unless APPLY=1 (FORCE=1 overwrites existing). Passphrase read hidden.
	@REPO_DIR="$(CURDIR)" CTL_IMAGE="$(CTL_IMAGE)" CTL_CFG_DIR="$(CTL_CFG_DIR)" VAULT_ENV_PROJECT="$(VAULT42_PROJECT)" \
		sh apps/grobase/scripts/vault/ctl-env.sh pull $(if $(filter 1,$(APPLY)),--apply,) $(if $(filter 1,$(FORCE)),--force,)

bootstrap:
## FROM-ZERO one command (fresh clone / clean Docker / wiped machine): keystore check → submodules → secrets ← vault42 → grobase backend (builds+pulls all images) → restore all-engine data → frontends. Brings the whole stack back from 0 B of Docker. The data restore is DESTRUCTIVE (drop-and-replace) — meant for an empty/fresh setup. Prereq: copy ~/.config/42ctl/keystore.v42 over first (the only file in neither git nor the vault).
	@if [ ! -f "$(CTL_CFG_DIR)/keystore.v42" ]; then \
		echo '[bootstrap] MISSING vault key: $(CTL_CFG_DIR)/keystore.v42' >&2; \
		echo '            It is the vault42 master key — the one secret in neither git nor the vault itself.' >&2; \
		echo '            Copy it from your old machine first (scp / USB), then re-run make bootstrap, e.g.:' >&2; \
		echo '              mkdir -p $(CTL_CFG_DIR) && scp OLD_HOST:~/.config/42ctl/keystore.v42 $(CTL_CFG_DIR)/' >&2; \
		exit 1; \
	fi
	@echo '── bootstrap 1/4 · submodules → stable branches ──────────────────────'
	@$(MAKE) --no-print-directory syncro-submodule
	@echo '── bootstrap 2/4 · secrets ← vault42 (keystore passphrase prompt) ─────'
	@$(MAKE) --no-print-directory vault42-pull-all APPLY=1
	@echo '── bootstrap 3/4 · grobase backend up (builds + pulls all images) ─────'
	@$(MAKE) -C apps/grobase up
	@echo '── bootstrap 4/4 · frontends + auto-restore all-engine data ───────────'
	@$(MAKE) --no-print-directory all SKIP_SYNC=1
	@echo '✓ bootstrap complete — everything is back. Login: dev.pro.photo / Osionos123!'

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

repair-detached:
## Re-attach every detached submodule HEAD: commit dirty state, merge onto main, push main + develop.
	@set -eu; \
	git submodule foreach --recursive 'set -eu; \
		branch=$$(git symbolic-ref --short -q HEAD 2>/dev/null || true); \
		if [ -n "$$branch" ]; then \
			echo "[repair] $$displaypath already on $$branch — skipping"; \
			exit 0; \
		fi; \
		echo "[repair] $$displaypath is detached — fixing"; \
		git add -A; \
		if ! git diff --cached --quiet; then \
			git commit -m "$(GIT_COMMIT_MESSAGE)"; \
		fi; \
		tmp="tmp/detached-$$(git rev-parse --short HEAD)"; \
		git checkout -b "$$tmp"; \
		if git rev-parse --verify main >/dev/null 2>&1; then \
			git checkout main; \
			git merge --no-ff "$$tmp" -m "merge: bring detached work onto main" || true; \
		else \
			git checkout -b main; \
		fi; \
		git push -u origin main; \
		if git ls-remote --exit-code --heads origin develop >/dev/null 2>&1; then \
			git checkout develop 2>/dev/null || git checkout -b develop origin/develop; \
			git merge --no-ff main -m "merge: sync develop from main" || true; \
		else \
			git checkout -b develop; \
		fi; \
		git push -u origin develop; \
		git checkout main; \
		git branch -d "$$tmp" 2>/dev/null || true \
	'

pushes:
## Add, commit, and push the root repo plus every recursive submodule. Use GIT_COMMIT_MESSAGE="...".
	@set -eu; \
	repos="$$(git submodule foreach --quiet --recursive 'printf "%s\n" "$$displaypath"' | awk '{ print length, $$0 }' | sort -rn | cut -d' ' -f2-)"; \
	printf '%s\n.\n' "$$repos" | while IFS= read -r repo; do \
		[ -n "$$repo" ] || continue; \
		if ! git -C "$$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then continue; fi; \
		branch="$$(git -C "$$repo" symbolic-ref --short -q HEAD || true)"; \
		if [ -z "$$branch" ]; then echo "[pushes] $$repo is detached — run 'make repair-detached' first"; continue; fi; \
		echo "[pushes] $$repo ($$branch)"; \
		git -C "$$repo" add -A; \
		if ! git -C "$$repo" diff --cached --quiet; then \
			git -C "$$repo" commit -m '$(GIT_COMMIT_MESSAGE)'; \
		else \
			echo "[pushes] $$repo has no staged changes"; \
		fi; \
		if git -C "$$repo" ls-remote --exit-code --heads origin "$$branch" >/dev/null 2>&1; then \
			git -C "$$repo" fetch origin "$$branch"; \
			git -C "$$repo" merge --ff-only "origin/$$branch" 2>/dev/null || true; \
		fi; \
		if git -C "$$repo" rev-parse --verify --quiet '@{u}' >/dev/null; then \
			git -C "$$repo" push; \
		else \
			git -C "$$repo" push -u '$(GIT_PUSH_REMOTE)' "$$branch"; \
		fi; \
	done
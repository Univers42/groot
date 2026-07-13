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

secrets-ensure:
## Fresh-machine secret provisioning, wired into `make all`. If grobase secrets are ABSENT but a vault42 keystore is present, pull the whole *.env tree from vault42 — non-interactive when FT_PASSPHRASE/VAULT42_PASSPHRASE is set (CI), else one hidden prompt. Secrets already present → no-op. No keystore → LOCAL mode directly. A vault-PULL FAILURE (shared vault unreachable/empty) is NOT fatal — it falls back LOUDLY to the same LOCAL mode (grobase self-generates its own secrets; ./.env.local is derived after backend-up via env-local-ensure) instead of aborting `make all`. This is what lets a bare `make all` provision a clean machine end-to-end even when the shared vault is down.
	@if [ -f apps/grobase/.env ]; then \
		printf '[secrets] grobase/.env present — skipping vault pull\n'; \
	elif [ -f "$(CTL_CFG_DIR)/keystore.v42" ]; then \
		printf '[secrets] fresh machine — pulling *.env tree from vault42 (project=%s)…\n' "$(VAULT42_PROJECT)"; \
		if $(MAKE) --no-print-directory vault42-pull-all APPLY=1 FORCE=1; then \
			printf '[secrets] vault42 pull applied\n'; \
		else \
			rc=$$?; \
			rm -f apps/grobase/.env; \
			printf '\n[secrets] ################################################################\n' >&2; \
			printf '[secrets] # WARNING: vault42 pull FAILED (exit %s) — the SHARED vault secrets\n' "$$rc" >&2; \
			printf '[secrets] # are UNAVAILABLE (see the ctl-env.sh error above). Falling back to\n' >&2; \
			printf '[secrets] # LOCAL mode: grobase will self-generate its OWN secrets and\n' >&2; \
			printf '[secrets] # ./.env.local will be derived from them (env-local-ensure, after\n' >&2; \
			printf '[secrets] # backend-up). This stack will NOT share secrets/data with the team\n' >&2; \
			printf '[secrets] # until a human restores the vault (make vault42-push-all) and this\n' >&2; \
			printf '[secrets] # target is re-run.\n' >&2; \
			printf '[secrets] ################################################################\n\n' >&2; \
		fi; \
	else \
		printf '[secrets] no grobase/.env and no vault42 keystore at %s — LOCAL mode: grobase self-generates its secrets; ./.env.local is derived after backend-up (env-local-ensure).\n' "$(CTL_CFG_DIR)/keystore.v42"; \
	fi

.PHONY: env-local-ensure
env-local-ensure:
## Wired into `make all` AFTER backend-up. When there is no root ./.env.local (no-vault fresh machine), derive it from the now-generated apps/grobase/.env so the frontends authenticate against the freshly self-generated backend. No-op when ./.env.local already exists (vault-pulled or hand-edited).
	@bash scripts/gen-local-env.sh

bootstrap:
## Thin alias kept for muscle memory — `make all` is now self-provisioning (it runs secrets-ensure + brings the backend up), so `make bootstrap` simply runs it. FROM-ZERO on a clean machine: copy ~/.config/42ctl/keystore.v42 over first (the only file in neither git nor the vault), then `make all`. The data restore is DESTRUCTIVE on an EMPTY stack only (restore-if-empty never wipes populated data).
	@if [ ! -f "$(CTL_CFG_DIR)/keystore.v42" ] && [ -z "$${FT_PASSPHRASE:-}$${VAULT42_PASSPHRASE:-}" ]; then \
		echo '[bootstrap] no vault key at $(CTL_CFG_DIR)/keystore.v42 — running in LOCAL no-vault mode:' >&2; \
		echo '            grobase self-generates its secrets and ./.env.local is derived locally.' >&2; \
		echo '            (To restore the SHARED secrets + demo data instead, copy ~/.config/42ctl/keystore.v42 over first.)' >&2; \
	fi
	@$(MAKE) --no-print-directory all
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
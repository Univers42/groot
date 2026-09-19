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
# The project name is the manifest key in the vault — get it wrong and `secrets-ensure`
# fails with "no manifest for project X" and falls back to LOCAL mode, so a fresh machine
# silently comes up with self-generated secrets instead of the team's. Measured on a clean
# clone: this said `transcendence`, the vault holds `groot`, and the whole bootstrap
# reported success while sharing nothing. Override per-machine with VAULT42_PROJECT=.
VAULT42_PROJECT ?= groot
# The org + environment that make the transfer SHARED. With both set, ctl-env.sh
# uses `42ctl env push/pull`, which seals every file to the ENVIRONMENT's key so
# any member granted the project can restore it. Blank either one and it falls
# back to `42ctl push/pull`, which seals to the CALLER ALONE — the whole tree is
# then unreadable by anyone else, and a teammate's pull fails with "no manifest
# for project groot" however much admin they hold in the org. That was the real
# cause of a colleague being unable to bootstrap: a personal backup had been
# mistaken for a team share. Verified live: org univers42 → project groot
# (c13b8692-855b-40c8-8123-6d57f63a93af) → env prod.
# NOTE: `*.local` is ALWAYS private in a shared environment, flag or not — a
# .env.local never reaches a teammate, as bytes or as a path. The root
# ./.env.local is therefore DERIVED on their machine by env-local-ensure
# (scripts/gen-local-env.sh) from the apps/grobase/.env that does travel.
VAULT42_ORG ?= univers42
VAULT42_ENV ?= prod
# Breadcrumb dropped when LOCAL mode is taken; see secrets-ensure. Deliberately NOT
# named .env* — ctl-env.sh's push scan captures `.env`, `.env.*`, `*.env`, `*.secrets`
# and `*.secret`, so an .env-shaped marker would be uploaded to the shared vault and
# then RESTORED onto every other machine's pull, flipping healthy machines into
# local-mode. A per-machine marker must not travel through the shared store.
LOCAL_MODE_MARK := .vault42-local-mode
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
		git submodule update --init --recursive || \
			echo "  ! $$displaypath: nested submodule init failed"; \
	'; \
	echo '[syncro] verify nothing is left detached…'; \
	bad=$$(git submodule foreach --quiet --recursive 'git symbolic-ref -q HEAD >/dev/null 2>&1 || printf "%s " "$$displaypath"' || true); \
	if [ -n "$$bad" ]; then echo "[syncro] STILL DETACHED (likely dirty/diverged): $$bad" >&2; fi; \
	echo '[syncro] done. Now: make all   (rebuilds frontends from the synced source)'

.PHONY: vault42-team-push vault42-team-pull
vault42-team-push:
## vault42 TEAM: publish this whole checkout to the shared environment $(VAULT42_ORG)/$(VAULT42_PROJECT)/$(VAULT42_ENV) — sealed to the ENV key, so every member granted the project can open it (the personal `vault42-push-all` seals to you alone and is readable by nobody else). Run it from a complete checkout with ./secrets holding fresh dumps. NOTE: agents are blocked from sending secrets off-box — run this yourself.
	@sh scripts/vault42-team.sh push

vault42-team-pull:
## vault42 TEAM: restore the shared environment's tree here — DRY-RUN unless APPLY=1. ONLY='secrets/*' limits the set; BACKUP=1 writes each displaced file aside as .bak. After an applied pull it rebuilds ./.env.local (gen-local-env.sh) and lays the owner-published team keys over it, without which a fresh OSIONOS_BRIDGE_EMAIL_HASH_SALT makes every restored identity unfindable.
	@sh scripts/vault42-team.sh pull \
		$(if $(filter 1,$(APPLY)),--apply,) \
		$(if $(filter 1,$(BACKUP)),--backup,) \
		$(if $(ONLY),--only '$(ONLY)',)

vault42-push-all:
## vault42: push the WHOLE monorepo *.env*/*.secrets tree (root + every submodule) to the SHARED environment ($(VAULT42_ORG)/$(VAULT42_PROJECT)/$(VAULT42_ENV)), sealed to the env key so every granted member can read it. Encrypted on this machine; passphrase read hidden. Blank VAULT42_ORG or VAULT42_ENV to fall back to the PERSONAL push (readable by nobody but you). NOTE: agents are blocked from sending secrets off-box — run this yourself.
	@REPO_DIR="$(CURDIR)" CTL_IMAGE="$(CTL_IMAGE)" CTL_CFG_DIR="$(CTL_CFG_DIR)" VAULT_ENV_PROJECT="$(VAULT42_PROJECT)" \
		VAULT_ENV_ORG="$(VAULT42_ORG)" VAULT_ENV_NAME="$(VAULT42_ENV)" \
		sh apps/grobase/scripts/vault/ctl-env.sh push

vault42-pull-all:
## vault42: restore the WHOLE monorepo *.env* tree from the SHARED environment ($(VAULT42_ORG)/$(VAULT42_PROJECT)/$(VAULT42_ENV)) — DRY-RUN unless APPLY=1. Passphrase read hidden. FORCE=1 is accepted for muscle memory but has no meaning for a shared env (use BACKUP=1, which writes the displaced file aside). Blank VAULT42_ORG or VAULT42_ENV for the PERSONAL pull.
	@REPO_DIR="$(CURDIR)" CTL_IMAGE="$(CTL_IMAGE)" CTL_CFG_DIR="$(CTL_CFG_DIR)" VAULT_ENV_PROJECT="$(VAULT42_PROJECT)" \
		VAULT_ENV_ORG="$(VAULT42_ORG)" VAULT_ENV_NAME="$(VAULT42_ENV)" \
		sh apps/grobase/scripts/vault/ctl-env.sh pull $(if $(filter 1,$(APPLY)),--apply,) $(if $(filter 1,$(BACKUP)),--backup,) $(if $(filter 1,$(FORCE)),--force,)

secrets-ensure:
## Fresh-machine secret provisioning, wired into `make all`. If grobase secrets are ABSENT but a vault42 keystore is present, pull the whole *.env tree from vault42 — non-interactive when FT_PASSPHRASE/VAULT42_PASSPHRASE is set (CI), else one hidden prompt. Secrets already present → no-op. No keystore → LOCAL mode directly. A vault-PULL FAILURE (shared vault unreachable/empty) is NOT fatal — it falls back LOUDLY to the same LOCAL mode (grobase self-generates its own secrets; ./.env.local is derived after backend-up via env-local-ensure) instead of aborting `make all`. This is what lets a bare `make all` provision a clean machine end-to-end even when the shared vault is down. LOCAL mode drops the marker .vault42-local-mode, and while it exists EVERY later run prints a loud banner saying the machine is on self-generated secrets — without it, the first branch below silently skips the pull forever and `make all` reports success while sharing nothing. Recovery is NOT automatic: the data volumes were initialised with the local secrets and POSTGRES_PASSWORD only applies to an empty PGDATA, so the banner names the (destructive) steps instead.
	@if [ "$(VAULT42_SOURCE)" = 'team' ] && [ ! -f apps/grobase/.env ]; then \
		printf '[secrets] VAULT42_SOURCE=team — pulling the SHARED environment %s/%s/%s\n' \
			'$(VAULT42_ORG)' '$(VAULT42_PROJECT)' '$(VAULT42_ENV)'; \
		$(MAKE) --no-print-directory vault42-team-pull APPLY=1 || { \
			printf '\n[secrets] ################################################################\n' >&2; \
			printf '[secrets] # TEAM pull FAILED and VAULT42_SOURCE=team forbids the fallback.\n' >&2; \
			printf '[secrets] # Coming up on self-generated secrets would give this machine a\n' >&2; \
			printf '[secrets] # stack that shares nothing and whose volumes are then pinned to\n' >&2; \
			printf '[secrets] # those secrets — the expensive failure this flag exists to stop.\n' >&2; \
			printf '[secrets] # Fix the cause above, then re-run. Drop VAULT42_SOURCE to accept\n' >&2; \
			printf '[secrets] # LOCAL mode deliberately.\n' >&2; \
			printf '[secrets] ################################################################\n\n' >&2; \
			exit 1; \
		}; \
		rm -f $(LOCAL_MODE_MARK); \
		printf '[secrets] shared environment applied\n'; \
	elif [ -f apps/grobase/.env ]; then \
		if [ -f $(LOCAL_MODE_MARK) ]; then \
			printf '\n[secrets] ################################################################\n' >&2; \
			printf '[secrets] # THIS MACHINE IS IN LOCAL MODE — its secrets are self-generated,\n' >&2; \
			printf '[secrets] # NOT the team'"'"'s. Nothing here is shared with anybody. The marker\n' >&2; \
			printf '[secrets] # %s says a previous run fell back; grobase/.env exists, so\n' "$(LOCAL_MODE_MARK)" >&2; \
			printf '[secrets] # the vault pull is skipped and will STAY skipped until you act.\n' >&2; \
			printf '[secrets] #\n' >&2; \
			printf '[secrets] # It is not auto-repaired: the data volumes were initialised with\n' >&2; \
			printf '[secrets] # THESE secrets, and POSTGRES_PASSWORD is only honoured by initdb on\n' >&2; \
			printf '[secrets] # an empty PGDATA — swapping the files under a live volume locks the\n' >&2; \
			printf '[secrets] # stack out of its own database. Recovery discards local data:\n' >&2; \
			printf '[secrets] #\n' >&2; \
			printf '[secrets] #   docker compose -p mini-baas down -v --remove-orphans\n' >&2; \
			printf '[secrets] #   rm -f apps/grobase/.env apps/grobase/.env.secrets \\\n' >&2; \
			printf '[secrets] #         apps/grobase/.env.local ./.env.local %s\n' "$(LOCAL_MODE_MARK)" >&2; \
			printf '[secrets] #   make all\n' >&2; \
			printf '[secrets] ################################################################\n\n' >&2; \
		else \
			printf '[secrets] grobase/.env present — skipping vault pull\n'; \
		fi; \
	elif [ -f "$(CTL_CFG_DIR)/keystore.v42" ]; then \
		printf '[secrets] fresh machine — pulling *.env tree from vault42 (project=%s)…\n' "$(VAULT42_PROJECT)"; \
		if $(MAKE) --no-print-directory vault42-pull-all APPLY=1 FORCE=1; then \
			printf '[secrets] vault42 pull applied\n'; \
			rm -f $(LOCAL_MODE_MARK); \
		else \
			rc=$$?; \
			rm -f apps/grobase/.env; \
			touch $(LOCAL_MODE_MARK); \
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
		touch $(LOCAL_MODE_MARK); \
		printf '[secrets] no grobase/.env and no vault42 keystore at %s — LOCAL mode: grobase self-generates its secrets; ./.env.local is derived after backend-up (env-local-ensure).\n' "$(CTL_CFG_DIR)/keystore.v42"; \
	fi

.PHONY: env-local-ensure
env-local-ensure:
## Wired into `make all` AFTER backend-up. When there is no root ./.env.local (no-vault fresh machine), derive it from the now-generated apps/grobase/.env so the frontends authenticate against the freshly self-generated backend. No-op when ./.env.local already exists (vault-pulled or hand-edited). Then `--sync` refreshes ONLY the seven derived BaaS keys (JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY, KONG_*, SB_KONG_KEY, ADAPTER_REGISTRY_SERVICE_TOKEN) from apps/grobase/.env, in place — an existing file can no longer keep a stale Kong key, the recurring healthcheck 401. `bash scripts/gen-local-env.sh --check` reports drift by key name.
	@bash scripts/gen-local-env.sh
	@bash scripts/gen-local-env.sh --sync || printf '[env-local-ensure] derived keys not all refreshed — inspect: bash scripts/gen-local-env.sh --check\n' >&2

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
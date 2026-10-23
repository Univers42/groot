# The vault42 CLI (vendor/scripts/vault42) driven by utils/vault42.conf. Every target is one call of
# it; the logic lives in the CLI and is tested there. The old path (vault42-team-*, vault42-*-all)
# stays beside it until the retirement checklist in docs/adr/0017-vault42-cli-beside-the-old-path.md
# is done.
VAULT42_CLI := vendor/scripts/vault42/vault42.sh
VAULT42_BIN = bash $(VAULT42_CLI) --config utils/vault42.conf

# A variable counts only when typed on the make command line. APPLY, YES and ALL can overwrite or
# replace a whole vault tree, and a stray `export YES=1` in a shell profile must not confirm it.
# Caveat: `override VAR=` inside a makefile has origin `override` and is ignored too.
vault42_arg = $(if $(findstring command line,$(origin $(1))),$($(1)))
vault42_flag = $(if $(filter 1,$(call vault42_arg,$(1))),$(2))
vault42_q = '$(subst ','\'',$(1))'
vault42_each = $(foreach w,$(call vault42_arg,$(2)),$(1) $(call vault42_q,$(w)))
vault42_target = --target $(call vault42_q,$(or $(call vault42_arg,TARGET),secrets))
vault42_kinds = $(call vault42_each,--kind,KIND)

# The vault coordinates are not overridable: a push to the wrong env is irreversible, so moving
# them takes an edit of utils/vault42.conf that a reviewer sees. Caveat: this guards the make
# entry only; bash vendor/scripts/vault42/vault42.sh --config <another file> still goes anywhere.
vault42_pinned = $(strip $(foreach v,VAULT42_ORG VAULT42_PROJECT VAULT42_ENV,$(if $(filter command environment,$(firstword $(origin $(v)))),$(v))))
vault42_guard = \
	if [ -n '$(vault42_pinned)' ]; then \
		echo "make: $(vault42_pinned) cannot be set here; edit utils/vault42.conf" >&2; exit 2; \
	fi; \
	if [ ! -f $(VAULT42_CLI) ]; then \
		echo "make: $(VAULT42_CLI) is missing; run: git submodule update --init vendor/scripts" >&2; exit 1; \
	fi;
vault42_need = if [ -z $(call vault42_q,$(call vault42_arg,$(1))) ]; then echo "usage: $(2)" >&2; exit 2; fi;

##@ Secrets (vault42)
vault42-status: ## Check 42ctl, the environment, the session and your key (read-only)
## Usage: make vault42-status [TARGET=secrets]
## TARGET=volumes checks the volumes target's key instead. Reads FT_PASSPHRASE from the environment. Exit 5 when it is missing.
	@$(vault42_guard) $(VAULT42_BIN) $(vault42_target) doctor

vault42-login: ## Log in to the vault42 authority with FT_EMAIL, FT_PASSWORD, FT_TENANT
## Credentials come from the environment only; nothing is written to a file.
	@$(vault42_guard) $(VAULT42_BIN) login

vault42-list: ## List the files the vault holds, with size and private flag
## Usage: make vault42-list [KIND="env secrets"] [TARGET=secrets]
## TARGET is a section of utils/vault42.conf (secrets or volumes). KIND is space-separated and
## defaults to the target's kinds (volumes need KIND=volumes). Read-only.
	@$(vault42_guard) $(VAULT42_BIN) $(vault42_target) $(vault42_kinds) list

vault42-diff: ## Show what a push or a pull would change, by size (read-only)
## Usage: make vault42-diff [KIND="env secrets"] [TARGET=secrets]
## +local only, -vault only, ~size differs. Size only: a same-size edit is not shown.
	@$(vault42_guard) $(VAULT42_BIN) $(vault42_target) $(vault42_kinds) diff

vault42-pull: ## Preview the vault's tree; APPLY=1 writes it here (post_pull on full pulls)
## Usage: make vault42-pull [KIND="env secrets"] [TARGET=secrets] [ONLY="a b"] [APPLY=1]
## A preview unless APPLY=1 is typed on the command line (an exported APPLY is ignored). ONLY
## limits the restore to those paths. After an applied pull utils/scripts/vault42-post-pull.sh
## rebuilds .env.local and lays the team/env-local secret over it; with ONLY, or a KIND without
## env, the hook does not run (a partial restore is not the environment it rebuilds from) and the
## CLI prints the command.
	@$(vault42_guard) $(VAULT42_BIN) $(vault42_target) $(vault42_kinds) pull $(call vault42_flag,APPLY,--apply) $(call vault42_each,--only,ONLY)

vault42-push: ## Replace the vault's tree with this checkout (asks first; YES=1 skips)
## Usage: make vault42-push [FILE="a b"] [KIND="env secrets"] [TARGET=secrets] [YES=1]
## REPLACES the shared tree every teammate pulls. scripts/vault42-push-guard.sh runs first.
## FILE pushes only those paths. YES=1 skips the question and only counts when typed on the
## command line. The verified path is still make vault42-team-push: this one stays unproven
## against the real vault until the operator has done R1-R6 of
## docs/adr/0017-vault42-cli-beside-the-old-path.md.
	@$(vault42_guard) $(VAULT42_BIN) $(vault42_target) $(vault42_kinds) push $(call vault42_flag,YES,--yes) $(foreach f,$(call vault42_arg,FILE),$(call vault42_q,$(f)))

vault42-secret-get: ## Print one vault secret (KEY=<path>) on stdout
## Usage: make vault42-secret-get KEY=team/env-local
	@$(call vault42_need,KEY,make vault42-secret-get KEY=<path>) $(vault42_guard) $(VAULT42_BIN) --target secrets secret get $(call vault42_q,$(call vault42_arg,KEY))

vault42-secret-set: ## Store stdin as one vault secret (KEY=<path>)
## Usage: make vault42-secret-set KEY=team/env-local < value
## The value is read from stdin so it never reaches argv or the shell history.
	@$(call vault42_need,KEY,make vault42-secret-set KEY=<path> < value) $(vault42_guard) $(VAULT42_BIN) --target secrets secret set $(call vault42_q,$(call vault42_arg,KEY))

vault42-volumes-list: ## List docker data volumes and whether each is archived
## Needs docker and the volumes root of utils/vault42.conf (VAULT42_VOLUMES_ROOT overrides it).
	@$(vault42_guard) $(VAULT42_BIN) --target volumes volumes list

vault42-volumes-capture: ## Archive docker volumes (stops their containers while it copies)
## Usage: make vault42-volumes-capture [ONLY="vol1 vol2"]
## A cold copy: containers using a volume are stopped and restarted on every exit path.
## Refused when the stack is staging or prod. Pushing the archives is a separate step.
	@$(vault42_guard) $(VAULT42_BIN) --target volumes volumes capture $(call vault42_each,--only,ONLY)

vault42-volumes-restore: ## Restore volumes from archives (DESTRUCTIVE; ARCHIVE=<file> or ALL=1)
## Usage: make vault42-volumes-restore ARCHIVE=secrets/volume-x.tar.gz | ALL=1
## Overwrites the named docker volume(s). ALL=1 only counts when typed on the command line.
	@if [ -z $(call vault42_q,$(call vault42_arg,ARCHIVE)$(call vault42_flag,ALL,all)) ]; then echo "usage: make vault42-volumes-restore ARCHIVE=<file> | ALL=1" >&2; exit 2; fi; \
		$(vault42_guard) $(VAULT42_BIN) --target volumes volumes restore $(if $(call vault42_flag,ALL,1),--all,$(call vault42_q,$(call vault42_arg,ARCHIVE)))

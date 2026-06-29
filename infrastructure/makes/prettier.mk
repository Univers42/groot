# **************************************************************************** #
#                                                                              #
#    prettier.mk — monorepo-wide formatting ("pretty") targets                 #
#                                                                              #
#    Docker-first: every formatter runs in a container (no host                #
#    node/go/rust/shfmt). Two modes per language:                              #
#      pretty-<x>        format in place                                       #
#      pretty-<x>-check  verify WITHOUT writing (CI gate; non-zero on drift)   #
#                                                                              #
#    Scope = ROOT-OWNED files only (apps/ and vendor/ carry their own          #
#    toolchains — grobase via `pretty-grobase`). File lists come from          #
#    `git ls-files` at recipe-time (tracked files only, no glob-miss errors).  #
#    `pretty` / `pretty-check` aggregate shell·yaml·md. `pretty-all` adds      #
#    grobase. Help text uses the root convention: `## ` on the line AFTER the  #
#    target (see common.mk help awk).                                          #
# **************************************************************************** #

PRETTIER_IMG  ?= node:20-alpine
SHFMT_IMG     ?= mvdan/shfmt:latest
PRETTIER_VER  ?= 3.4.2
NPM_CACHE_VOL ?= track-binocle-npm-cache

# git-ls-files selectors, evaluated at recipe-time (not make-parse time).
SEL_SH   := git ls-files '*.sh' | grep -vE '^(apps|vendor)/'
SEL_YAML := git ls-files '*.yml' '*.yaml' | grep -vE '^(apps|vendor)/'
SEL_MD   := git ls-files '*.md' | grep -vE '/'   # root-level docs only (not the hand-authored wiki tree)

_PRETTIER_RUN = docker run --rm -e NPM_CONFIG_UPDATE_NOTIFIER=false -v "$(CURDIR)":/d -w /d -v $(NPM_CACHE_VOL):/root/.npm $(PRETTIER_IMG) npx --yes prettier@$(PRETTIER_VER)
_SHFMT_RUN    = docker run --rm -v "$(CURDIR)":/d -w /d $(SHFMT_IMG)

pretty: pretty-shell pretty-yaml pretty-md
## Format the monorepo's root-owned files in place (shell·yaml·md)
	@printf '\033[0;32m✓ pretty: root shell·yaml·md formatted\033[0m\n'

pretty-check: pretty-shell-check pretty-yaml-check pretty-md-check
## Verify root formatting without writing (CI gate)
	@printf '\033[0;32m✓ pretty-check: every root file is formatted\033[0m\n'

pretty-all: pretty pretty-grobase
## Format EVERYTHING — root-owned files + grobase's own formatters

pretty-shell:
## Format root shell scripts in place — shfmt -i 2 (Docker)
	@f=$$($(SEL_SH)); [ -z "$$f" ] && { echo "no root shell"; exit 0; }; \
		$(_SHFMT_RUN) -w -i 2 $$f && printf '\033[0;32m✓ shell (shfmt -w)\033[0m\n'

pretty-shell-check:
## Check root shell formatting — shfmt -l (Docker)
	@f=$$($(SEL_SH)); [ -z "$$f" ] && { echo "no root shell"; exit 0; }; \
		out=$$($(_SHFMT_RUN) -l -i 2 $$f 2>&1 || true); \
		[ -z "$$out" ] && printf '\033[0;32m✓ shell formatted\033[0m\n' \
		|| { printf '\033[0;31m✗ shell needs formatting:\033[0m\n%s\n' "$$out"; exit 1; }

pretty-yaml:
## Format root YAML in place — prettier (Docker)
	@f=$$($(SEL_YAML)); [ -z "$$f" ] && { echo "no root yaml"; exit 0; }; \
		$(_PRETTIER_RUN) --write $$f && printf '\033[0;32m✓ yaml (prettier)\033[0m\n'

pretty-yaml-check:
## Check root YAML formatting — prettier --check (Docker)
	@f=$$($(SEL_YAML)); [ -z "$$f" ] && { echo "no root yaml"; exit 0; }; \
		$(_PRETTIER_RUN) --check $$f && printf '\033[0;32m✓ yaml formatted\033[0m\n'

pretty-md:
## Format root-level Markdown docs in place — prettier (Docker; excludes the wiki tree)
	@f=$$($(SEL_MD)); [ -z "$$f" ] && { echo "no root markdown"; exit 0; }; \
		$(_PRETTIER_RUN) --write $$f && printf '\033[0;32m✓ md (prettier)\033[0m\n'

pretty-md-check:
## Check root-level Markdown formatting — prettier --check (Docker; excludes the wiki tree)
	@f=$$($(SEL_MD)); [ -z "$$f" ] && { echo "no root markdown"; exit 0; }; \
		$(_PRETTIER_RUN) --check $$f && printf '\033[0;32m✓ md formatted\033[0m\n'

pretty-grobase:
## Delegate: run grobase's own formatters (gofumpt·rustfmt·prettier·shfmt)
	@$(MAKE) -C apps/grobase prettiers

pretty-grobase-check:
## Delegate: verify grobase formatting (CI gate)
	@$(MAKE) -C apps/grobase prettiers-check

.PHONY: pretty pretty-check pretty-all pretty-shell pretty-shell-check \
	pretty-yaml pretty-yaml-check pretty-md pretty-md-check \
	pretty-grobase pretty-grobase-check

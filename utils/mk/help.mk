# Help is generated from the `##` markers in the makefiles themselves, so a new
# target documents itself and nothing is hand-listed. Convention: the awk header.
MAKE_HELP_AWK := utils/scripts/make-help.awk
HELP_SECTIONS := Pipeline|Link (grobase anywhere)|Backend (grobase)|Secrets (vault42)|Apps|Tests|Demo data|Certificates|Docker|Git & submodules|Formatting|Help

# Recursive on purpose: expands when the root `.PHONY:` line is read, after every
# module is included, so a module never lists its own targets as phony.
# Caveat: costs one awk run per make invocation (~ms); a target the awk cannot
# see (see its header) is not made phony.
MAKE_HELP_PHONY = $(shell awk -v mode=phony -f $(MAKE_HELP_AWK) $(MAKEFILE_LIST))

##@ Help
help: ## List every target by section; make help-<target> shows one in full
## Usage: make help
## Colour only on a terminal; NO_COLOR=1 turns it off there too.
	@color=0; if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ]; then color=1; fi; \
		awk -v mode=list -v color=$$color -v order='$(HELP_SECTIONS)' -f $(MAKE_HELP_AWK) $(MAKEFILE_LIST)

help-%: ## Show one target's summary, prerequisites and usage lines
## Usage: make help-<target>   (for example: make help-link)
## Exits 1 when the target has no documented summary.
	@color=0; if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ]; then color=1; fi; \
		awk -v mode=target -v color=$$color -v target='$(subst ','\'',$*)' -f $(MAKE_HELP_AWK) $(MAKEFILE_LIST)

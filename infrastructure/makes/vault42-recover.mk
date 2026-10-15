# vault42 retrieval with the native 42ctl and the operator's own account: everything the vault
# keeps for $(VAULT42_ORG)/$(VAULT42_PROJECT), and the engine dumps a later push dropped from
# the newest tree. Both are read-only on vault42 and load nothing into a database.
VAULT42_RECOVER_ENV = VAULT42_ORG='$(VAULT42_ORG)' VAULT42_PROJECT='$(VAULT42_PROJECT)' \
	VAULT42_ENV='$(VAULT42_ENV)' CTL_CFG_DIR='$(CTL_CFG_DIR)'

.PHONY: vault42-pull-everything vault42-recover-dumps
vault42-pull-everything:
## vault42: pull EVERYTHING $(VAULT42_ORG)/$(VAULT42_PROJECT) keeps — every environment's tree, the notes, the team handbook — then prove the dumps in ./secrets against SHA256SUMS. Previews first and writes after one "y"; YES=1 skips it. Loading the dumps is `make vault-restore`.
	@$(VAULT42_RECOVER_ENV) bash scripts/vault42-pull-everything.sh $(if $(filter 1,$(YES)),--yes,)

vault42-recover-dumps:
## vault42: bring back the dumps secrets/SHA256SUMS lists but the newest $(VAULT42_ENV) tree no longer names, from older push revisions and key epochs (42ctl + scripts/vault42-recover/42ctl-epoch.patch, built in a container). PHASE=all|build|probe|pull. Only a copy matching today's SHA256SUMS enters ./secrets; otherwise the newest is quarantined, labelled, in .vault42/recovered/.
	@$(VAULT42_RECOVER_ENV) bash scripts/vault42-recover-dumps.sh $(or $(PHASE),all)

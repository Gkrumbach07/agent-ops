# OpenShell on OpenShift: one-command entry points. Every target is safe to re-run.
# Set OPENSHELL_NAMESPACE to install somewhere other than "openshell".

TE := scripts/token-exchange

.PHONY: help preflight cli deploy token-exchange token-exchange-preflight try-it clean-demo

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-26s %s\n", $$1, $$2}'

preflight: ## Check the cluster is ready for OpenShell
	@./scripts/preflight.sh

cli: ## Install the OpenShell CLI (checksum-verified installer)
	@./scripts/install-openshell-cli.sh

deploy: preflight ## Install OpenShell, expose it, and connect the CLI
	@./scripts/deploy-openshell.sh

token-exchange-preflight:
	@./scripts/preflight.sh --token-exchange

token-exchange: token-exchange-preflight ## Set up per-sandbox identity and token exchange (steps 0 to 5)
	@OPENSHELL_ENABLE_SPIFFE=true ./scripts/deploy-openshell.sh
	@$(TE)/01-fix-ztwim-oidc.sh
	@$(TE)/02-sandbox-spiffe-ids.sh
	@$(TE)/03-deploy-keycloak.sh
	@$(TE)/04-configure-realm.sh
	@$(TE)/05-deploy-registrar.sh

try-it: ## Call a protected API from a sandbox as the demo user (step 6)
	@$(TE)/06-try-it.sh

clean-demo: ## Delete the try-it sandbox
	@openshell sandbox delete token-exchange-demo

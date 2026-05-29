# OpenShift Lightspeed demo — convenience targets.
# The complex, ordered flows (infra + waits) live in provision.sh, which these
# targets call so there is a single source of truth. Simple one-shot actions run
# oc directly. Nothing here hardcodes cluster-specific values.
#
# Common overrides:
#   make secret-openai TOKEN=sk-...
#   make selfhosted MODEL=gpt-oss-20b INSTANCE=g6.xlarge
#   make saas FEATURES=route,agent-troubleshooting

SHELL := /usr/bin/env bash
LS_NS := openshift-lightspeed
FEATURES ?= route,query-filters,token-quota,agent-troubleshooting
MODEL ?= gpt-oss-20b
INSTANCE ?= g6.xlarge
TOKEN ?=

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: web-terminal
web-terminal: ## Install the Web Terminal Operator (so users get an in-console terminal)
	oc apply -k bootstrap/web-terminal

.PHONY: operator
operator: ## Install the Lightspeed operator and wait for the OLSConfig CRD
	oc apply -k base/lightspeed-operator
	oc wait --for=condition=established crd/olsconfigs.ols.openshift.io --timeout=300s

.PHONY: secret-openai
secret-openai: ## Create the OpenAI key secret (TOKEN=sk-...)
	@test -n "$(TOKEN)" || { echo "set TOKEN=sk-..."; exit 1; }
	oc create secret generic openai-api-keys -n $(LS_NS) \
	  --from-literal=apitoken="$(TOKEN)" --dry-run=client -o yaml | oc apply -f -

.PHONY: secret-rhoai
secret-rhoai: ## Create the vLLM bearer-token secret (TOKEN=...)
	@test -n "$(TOKEN)" || { echo "set TOKEN=..."; exit 1; }
	oc create secret generic rhoai-vllm-token -n $(LS_NS) \
	  --from-literal=apitoken="$(TOKEN)" --dry-run=client -o yaml | oc apply -f -

.PHONY: saas
saas: ## Guided stand-up of PATTERN 1 (SaaS OpenAI); prompts for the API key
	./provision.sh --pattern saas --features "$(FEATURES)" --yes

.PHONY: infra
infra: ## Build the full self-hosted GPU + model-serving stack (no OLSConfig)
	./provision.sh --pattern selfhosted --model "$(MODEL)" --instance "$(INSTANCE)" \
	  --features "$(FEATURES)" --yes

.PHONY: selfhosted
selfhosted: infra ## Stand up PATTERN 2 (self-hosted); same as infra (infra builds + applies overlay)

.PHONY: switch-to-saas
switch-to-saas: ## Tear down current OLSConfig and switch to SaaS
	./provision.sh --switch --pattern saas --features "$(FEATURES)" --yes

.PHONY: switch-to-selfhosted
switch-to-selfhosted: ## Tear down current OLSConfig and switch to self-hosted
	./provision.sh --switch --pattern selfhosted --model "$(MODEL)" --features "$(FEATURES)" --yes

.PHONY: infra-check
infra-check: ## Report what is already provisioned (GPU nodes, operators, model)
	@echo "GPU capacity:"; oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -E '\t[1-9]' || echo "  none"
	@echo "RHOAI CSV:"; oc get csv -n redhat-ods-operator 2>/dev/null | grep -i rhods || echo "  not installed"
	@echo "InferenceServices:"; oc get inferenceservice -A 2>/dev/null || echo "  none"
	@echo "OLSConfig status:"; oc get olsconfig cluster -o jsonpath='{.status.overallStatus}{"\n"}' 2>/dev/null || echo "  none"

.PHONY: status
status: infra-check ## Alias for infra-check

.PHONY: uninstall
uninstall: ## Remove OLSConfig + overlays (keeps operator and infra)
	./provision.sh --uninstall --yes

.PHONY: uninstall-infra
uninstall-infra: ## Remove the self-hosted model-serving + GPU stack (DESTRUCTIVE)
	@echo "This deletes the model, RHOAI DSC, GPU operator policy, and the GPU MachineSet."
	@read -r -p "Type 'yes' to continue: " a; test "$$a" = yes || { echo aborted; exit 1; }
	-oc delete -k infra/60-model-serving
	-oc delete -k infra/50-datasciencecluster
	-oc delete -f infra/30-nvidia-gpu-operator/clusterpolicy.yaml
	-oc delete -k infra/10-gpu-machineset

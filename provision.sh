#!/usr/bin/env bash
# provision.sh — guided provisioning for OpenShift Lightspeed demos.
#
# Two patterns (mutually exclusive — OLSConfig is cluster-scoped, name "cluster"):
#   1) SaaS:        Lightspeed -> OpenAI hosted API
#   2) Self-hosted: Lightspeed -> a model you serve on OpenShift AI (vLLM) + full GPU stack
#
# Design: depends only on `oc` + bash + coreutils (no make/jq/python/yq), so it runs
# in the OpenShift Web Terminal. NOTHING cluster-specific is hardcoded — every
# environment value is read from the current `oc` session.
#
# Usage:
#   ./provision.sh                  # fully interactive
#   ./provision.sh --pattern saas --openai-key sk-... --features route,agent-troubleshooting --yes
#   ./provision.sh --pattern selfhosted --model gpt-oss-20b --instance g6.xlarge --vllm-token xxx --yes
#   ./provision.sh --switch         # flip to the other pattern (deletes OLSConfig, applies the other)
#   ./provision.sh --uninstall      # remove OLSConfig + overlays (keeps operator/infra)
set -euo pipefail

# --------------------------------------------------------------------------- #
# Constants (product/namespace facts, not environment-specific)
# --------------------------------------------------------------------------- #
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LS_NS="openshift-lightspeed"
LLM_NS="lightspeed-llm"
MACHINE_NS="openshift-machine-api"
OPENAI_SECRET="openai-api-keys"
RHOAI_SECRET="rhoai-vllm-token"
ALL_FEATURES="route query-filters token-quota agent-troubleshooting"

# Defaults (overridable by flags / env)
PATTERN="${PATTERN:-}"
MODEL="${MODEL:-gpt-oss-20b}"
INSTANCE="${INSTANCE:-g6.xlarge}"
FEATURES="${FEATURES:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
RHOAI_VLLM_TOKEN="${RHOAI_VLLM_TOKEN:-}"
ASSUME_YES="${ASSUME_YES:-false}"
ACTION="provision"   # provision | switch | uninstall

# --------------------------------------------------------------------------- #
# Pretty output
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else B=; G=; Y=; R=; C=; N=; fi
info()  { printf "%s\n" "${C}==>${N} $*"; }
ok()    { printf "%s\n" "${G}  ✓${N} $*"; }
warn()  { printf "%s\n" "${Y}  !${N} $*"; }
die()   { printf "%s\n" "${R}error:${N} $*" >&2; exit 1; }
hr()    { printf "%s\n" "------------------------------------------------------------"; }

confirm() {
  $ASSUME_YES && return 0
  local reply
  read -r -p "$1 [y/N] " reply </dev/tty || true
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --------------------------------------------------------------------------- #
# Arg parsing
# --------------------------------------------------------------------------- #
while [ $# -gt 0 ]; do
  case "$1" in
    --pattern)    PATTERN="${2:-}"; shift 2;;
    --model)      MODEL="${2:-}"; shift 2;;
    --instance)   INSTANCE="${2:-}"; shift 2;;
    --features)   FEATURES="${2:-}"; shift 2;;
    --openai-key) OPENAI_API_KEY="${2:-}"; shift 2;;
    --vllm-token) RHOAI_VLLM_TOKEN="${2:-}"; shift 2;;
    --switch)     ACTION="switch"; shift;;
    --uninstall)  ACTION="uninstall"; shift;;
    --yes|-y)     ASSUME_YES=true; shift;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

# --------------------------------------------------------------------------- #
# Preflight — uses the CURRENT oc session; never asks for URL/password
# --------------------------------------------------------------------------- #
preflight() {
  command -v oc >/dev/null 2>&1 || die "oc not found in PATH"
  oc whoami >/dev/null 2>&1 || die "not logged in. In the Web Terminal you are already logged in; otherwise run 'oc login' first."
  local user server console
  user="$(oc whoami)"
  server="$(oc whoami --show-server)"
  console="$(oc whoami --show-console 2>/dev/null || echo 'n/a')"
  hr; info "Target cluster (from your current oc session):"
  printf "    user:    %s\n    api:     %s\n    console: %s\n" "$user" "$server" "$console"; hr
  if ! oc auth can-i create clusterrolebindings >/dev/null 2>&1; then
    warn "you may not be cluster-admin; operator installs could fail."
  fi
  confirm "Proceed against THIS cluster?" || die "aborted by user."
}

# --------------------------------------------------------------------------- #
# Waiters (poll-based so they work without cluster-specific knowledge)
# --------------------------------------------------------------------------- #
wait_for() { # wait_for <seconds> <description> <command...>
  local timeout="$1" desc="$2"; shift 2
  local end=$(( SECONDS + timeout ))
  info "waiting for ${desc} (timeout ${timeout}s)…"
  while [ $SECONDS -lt $end ]; do
    if "$@" >/dev/null 2>&1; then ok "${desc}"; return 0; fi
    sleep 10
  done
  die "timed out waiting for ${desc}"
}

csv_succeeded() { # csv_succeeded <namespace> <name-prefix>
  oc get csv -n "$1" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -E "^$2.* Succeeded$" >/dev/null
}

# --------------------------------------------------------------------------- #
# Lightspeed operator
# --------------------------------------------------------------------------- #
ensure_operator() {
  info "installing the OpenShift Lightspeed operator…"
  oc apply -k "$REPO_DIR/base/lightspeed-operator"
  wait_for 600 "lightspeed-operator CSV Succeeded" csv_succeeded "$LS_NS" "lightspeed-operator"
  oc wait --for=condition=established crd/olsconfigs.ols.openshift.io --timeout=120s >/dev/null
  ok "OLSConfig CRD is registered."
}

# --------------------------------------------------------------------------- #
# Secrets (created out-of-band; values never written to disk/git)
# --------------------------------------------------------------------------- #
ensure_openai_secret() {
  if [ -z "$OPENAI_API_KEY" ]; then
    read -r -s -p "Enter your OpenAI API key (input hidden): " OPENAI_API_KEY </dev/tty; echo
  fi
  [ -n "$OPENAI_API_KEY" ] || die "no OpenAI API key provided."
  oc create secret generic "$OPENAI_SECRET" -n "$LS_NS" \
    --from-literal=apitoken="$OPENAI_API_KEY" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "secret ${OPENAI_SECRET} created in ${LS_NS}."
}

ensure_rhoai_secret() {
  if [ -z "$RHOAI_VLLM_TOKEN" ]; then
    read -r -s -p "Enter a bearer token for the vLLM endpoint (press Enter for 'novalue'): " RHOAI_VLLM_TOKEN </dev/tty; echo
    RHOAI_VLLM_TOKEN="${RHOAI_VLLM_TOKEN:-novalue}"
  fi
  oc create secret generic "$RHOAI_SECRET" -n "$LS_NS" \
    --from-literal=apitoken="$RHOAI_VLLM_TOKEN" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "secret ${RHOAI_SECRET} created in ${LS_NS}."
}

# --------------------------------------------------------------------------- #
# GPU MachineSet — generated by cloning an existing worker MachineSet (no jq/yq)
# --------------------------------------------------------------------------- #
generate_machineset() {
  info "generating a GPU MachineSet (instanceType=${INSTANCE}) from an existing worker…"
  local worker
  worker="$(oc get machineset -n "$MACHINE_NS" -o name 2>/dev/null | head -1 | sed 's#.*/##')"
  [ -n "$worker" ] || die "no worker MachineSet found in ${MACHINE_NS} (is this an IPI cluster?)."
  local out="$REPO_DIR/infra/10-gpu-machineset/machineset.yaml"
  oc get machineset "$worker" -n "$MACHINE_NS" -o yaml --show-managed-fields=false \
    | sed "/^status:/,\$d" \
    | grep -vE '^[[:space:]]*(creationTimestamp|resourceVersion|uid|generation|selfLink):' \
    | sed -e "s/${worker}/${worker}-gpu/g" \
          -e "s#instanceType:.*#instanceType: ${INSTANCE}#" \
          -e "s/replicas:.*/replicas: 1/" \
    > "$out"
  grep -q "instanceType: ${INSTANCE}" "$out" || die "failed to set instanceType in ${out}"
  ok "wrote ${out} (cloned from worker '${worker}')."
}

gpu_node_ready() {
  oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
    | grep -qE '^[1-9]'
}

# --------------------------------------------------------------------------- #
# Self-hosted infra (layers 10..60), ordered with waits
# --------------------------------------------------------------------------- #
apply_infra() {
  generate_machineset
  info "applying GPU MachineSet…";        oc apply -k "$REPO_DIR/infra/10-gpu-machineset"

  info "installing Node Feature Discovery operator…"
  oc apply -f "$REPO_DIR/infra/20-nfd/namespace.yaml"
  oc apply -f "$REPO_DIR/infra/20-nfd/operatorgroup.yaml"
  oc apply -f "$REPO_DIR/infra/20-nfd/subscription.yaml"
  wait_for 600 "NodeFeatureDiscovery CRD" oc get crd nodefeaturediscoveries.nfd.openshift.io
  oc apply -f "$REPO_DIR/infra/20-nfd/nodefeaturediscovery.yaml"

  info "installing NVIDIA GPU operator…"
  oc apply -f "$REPO_DIR/infra/30-nvidia-gpu-operator/namespace.yaml"
  oc apply -f "$REPO_DIR/infra/30-nvidia-gpu-operator/operatorgroup.yaml"
  oc apply -f "$REPO_DIR/infra/30-nvidia-gpu-operator/subscription.yaml"
  wait_for 600 "ClusterPolicy CRD" oc get crd clusterpolicies.nvidia.com
  oc apply -f "$REPO_DIR/infra/30-nvidia-gpu-operator/clusterpolicy.yaml"

  info "waiting for a GPU node to expose nvidia.com/gpu (driver install can take ~15-25 min)…"
  wait_for 2400 "schedulable GPU capacity" gpu_node_ready

  info "installing Red Hat OpenShift AI operator…"
  oc apply -k "$REPO_DIR/infra/40-rhoai-operator"
  wait_for 600 "rhods-operator CSV Succeeded" csv_succeeded "redhat-ods-operator" "rhods-operator"
  wait_for 300 "DataScienceCluster CRD" oc get crd datascienceclusters.datasciencecluster.opendatahub.io

  info "configuring single-model serving (KServe RawDeployment)…"
  oc apply -k "$REPO_DIR/infra/50-datasciencecluster"
  wait_for 900 "DataScienceCluster Ready" \
    bash -c "oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Ready"
  wait_for 600 "InferenceService CRD" oc get crd inferenceservices.serving.kserve.io

  resolve_vllm_image
  info "deploying the model (${MODEL}) with vLLM…"
  apply_model_serving
  wait_for 1800 "InferenceService ${MODEL} Ready" \
    oc wait --for=condition=Ready "inferenceservice/${MODEL}" -n "$LLM_NS" --timeout=5s
}

resolve_vllm_image() {
  # Best-effort: use the supported vLLM image from RHOAI's bundled template if present.
  local img
  img="$(oc get template -n redhat-ods-applications -o jsonpath='{range .items[*]}{.objects[0].spec.containers[0].image}{"\n"}{end}' 2>/dev/null | grep -m1 -i vllm || true)"
  if [ -n "$img" ]; then VLLM_IMAGE="$img"; ok "using cluster vLLM image: $img"; else VLLM_IMAGE=""; warn "could not resolve cluster vLLM image; using the tag in serving-runtime.yaml"; fi
}

apply_model_serving() {
  # Render layer 60 with the chosen model tag / served-model-name and (optional) image.
  oc apply -f "$REPO_DIR/infra/60-model-serving/namespace.yaml"
  local sr is
  sr="$(cat "$REPO_DIR/infra/60-model-serving/serving-runtime.yaml")"
  is="$(cat "$REPO_DIR/infra/60-model-serving/inference-service.yaml")"
  [ -n "${VLLM_IMAGE:-}" ] && sr="$(printf "%s" "$sr" | sed -e "s#image: quay.io/modh/vllm:.*#image: ${VLLM_IMAGE//#/\\#}#")"
  is="$(printf "%s" "$is" \
        | sed -e "s/name: gpt-oss-20b/name: ${MODEL}/g" \
              -e "s/--served-model-name=gpt-oss-20b/--served-model-name=${MODEL}/" \
              -e "s#modelcar-catalog:gpt-oss-20b#modelcar-catalog:${MODEL}#")"
  printf "%s\n" "$sr" | oc apply -f -
  printf "%s\n" "$is" | oc apply -f -
}

# --------------------------------------------------------------------------- #
# Overlay apply with selected feature components (temp kustomization)
# --------------------------------------------------------------------------- #
choose_features() {
  [ -n "$FEATURES" ] && return 0
  echo; info "Optional features (enable any; all are recommended for a full demo):"
  local sel=()
  for f in $ALL_FEATURES; do
    if confirm "  enable '${f}'?"; then sel+=("$f"); fi
  done
  FEATURES="$(IFS=,; echo "${sel[*]}")"
}

apply_overlay() { # apply_overlay <saas-openai|self-hosted-rhoai>
  local pattern="$1" tmp
  tmp="$(mktemp -d)"
  cp "$REPO_DIR/overlays/$pattern/olsconfig.yaml" "$tmp/olsconfig.yaml"
  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources:"
    echo "  - olsconfig.yaml"
    if [ -n "$FEATURES" ]; then
      echo "components:"
      local IFS=,; for f in $FEATURES; do echo "  - $REPO_DIR/components/$f"; done
    fi
  } > "$tmp/kustomization.yaml"
  info "applying OLSConfig (${pattern}) with features: ${FEATURES:-none}"
  oc apply -k "$tmp"
  rm -rf "$tmp"
}

set_selfhosted_url() {
  local url
  url="$(oc get inferenceservice "$MODEL" -n "$LLM_NS" -o jsonpath='{.status.url}' 2>/dev/null || true)"
  [ -n "$url" ] || die "could not read InferenceService URL; is the model Ready?"
  info "pointing Lightspeed at in-cluster endpoint ${url}/v1"
  oc patch olsconfig cluster --type=merge -p \
    "{\"spec\":{\"llm\":{\"providers\":[{\"name\":\"rhoai\",\"type\":\"rhoai_vllm\",\"credentialsSecretRef\":{\"name\":\"${RHOAI_SECRET}\"},\"models\":[{\"name\":\"${MODEL}\"}],\"url\":\"${url}/v1\"}]}}}" >/dev/null
  ok "OLSConfig provider URL set."
}

# --------------------------------------------------------------------------- #
# High-level flows
# --------------------------------------------------------------------------- #
choose_pattern() {
  [ -n "$PATTERN" ] && return 0
  echo; info "Which pattern do you want to stand up?"
  echo "    1) SaaS — OpenAI hosted API (fast; no GPUs; data leaves the cluster)"
  echo "    2) Self-hosted — OpenShift AI / vLLM + full GPU stack (data stays in-cluster)"
  local choice; read -r -p "Choose 1 or 2: " choice </dev/tty
  case "$choice" in 1) PATTERN=saas;; 2) PATTERN=selfhosted;; *) die "invalid choice";; esac
}

summary() {
  hr; ok "Done. Verify with:"
  echo "    oc get olsconfig cluster -o jsonpath='{.status.overallStatus}{\"\\n\"}'"
  echo "    oc get pods -n ${LS_NS}"
  oc get route -n "$LS_NS" lightspeed-app-server >/dev/null 2>&1 && \
    echo "    Route: https://$(oc get route -n "$LS_NS" lightspeed-app-server -o jsonpath='{.spec.host}')"
  echo
  echo "Open the OpenShift console, click the Lightspeed icon, and try Ask + Troubleshooting modes"
  echo "(see the Demo script in README.md)."; hr
}

provision_saas() {
  ensure_operator
  ensure_openai_secret
  choose_features
  apply_overlay "saas-openai"
  summary
}

provision_selfhosted() {
  ensure_operator
  ensure_rhoai_secret
  choose_features
  apply_infra
  apply_overlay "self-hosted-rhoai"
  set_selfhosted_url
  summary
}

do_switch() {
  info "removing current OLSConfig…"
  oc delete olsconfig cluster --ignore-not-found >/dev/null
  choose_pattern
  case "$PATTERN" in
    saas)       ensure_openai_secret; choose_features; apply_overlay "saas-openai";;
    selfhosted) ensure_rhoai_secret; choose_features; apply_overlay "self-hosted-rhoai"; set_selfhosted_url;;
  esac
  summary
}

do_uninstall() {
  warn "this removes the OLSConfig and demo overlays (operator + infra are left in place)."
  confirm "continue?" || die "aborted."
  oc delete olsconfig cluster --ignore-not-found
  oc delete route lightspeed-app-server -n "$LS_NS" --ignore-not-found
  ok "removed. Re-run ./provision.sh to stand a pattern back up."
}

# --------------------------------------------------------------------------- #
main() {
  preflight
  case "$ACTION" in
    switch)    do_switch;;
    uninstall) do_uninstall;;
    provision)
      choose_pattern
      case "$PATTERN" in
        saas)       provision_saas;;
        selfhosted) provision_selfhosted;;
        *) die "unknown pattern '$PATTERN' (use saas|selfhosted)";;
      esac;;
  esac
}
main "$@"

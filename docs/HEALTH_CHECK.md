# Health Check

Sandbox clusters lose their running pods on shutdown, but your config persists (the InferenceService args, OLSConfig, operators all live in etcd) — so this is about confirming each layer came back up, in dependency order. The two things that actually need to recover are the **GPU node** (driver reinit) and the **model pod** (reload + recompile):

```text
GPU node → operators → DataScienceCluster → model serving → OLSConfig → endpoint
```

Each layer waits on the one before it, and it's all self-healing — give it a few minutes after a cold start before worrying.

## Quick check (paste the whole block)

Model-agnostic — it auto-detects whichever model is deployed:

```bash
echo "== 1. Cluster / login =="
oc whoami && oc whoami --show-server || echo "NOT LOGGED IN"

echo; echo "== 2. GPU node (must expose nvidia.com/gpu) =="
oc get nodes -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status',GPU:'.status.allocatable.nvidia\.com/gpu'

echo; echo "== 3. Operators — all should say Succeeded =="
oc get csv -A 2>/dev/null | grep -iE 'lightspeed|nfd|gpu-operator|rhods' | awk '{print $1, $(NF)}'

echo; echo "== 4. DataScienceCluster (want: Ready) =="
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'

echo; echo "== 5. Model serving =="
oc get inferenceservice -n lightspeed-llm
oc get pods -n lightspeed-llm

echo; echo "== 6. Lightspeed =="
oc get olsconfig cluster -o jsonpath='overallStatus={.status.overallStatus}{"\n"}URL={.spec.llm.providers[0].url}{"\n"}defaultModel={.spec.ols.defaultModel}{"\n"}contextWindowSize={.spec.llm.providers[0].models[0].contextWindowSize}{"\n"}'
oc get pods -n openshift-lightspeed

echo; echo "== 7. Model endpoint reachable in-cluster =="
MODEL=$(oc get inferenceservice -n lightspeed-llm -o jsonpath='{.items[0].metadata.name}')
oc run gtest --rm -i --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -n lightspeed-llm -- \
  curl -s -m 8 "http://${MODEL}-predictor.lightspeed-llm.svc.cluster.local:8080/v1/models"
```

## What "healthy" looks like

| # | Healthy | If not |
| --- | --- | --- |
| 2 | GPU node `READY=True`, `GPU=1` | node still booting / driver reinitializing — wait 5–15 min; check `oc get pods -n nvidia-gpu-operator` |
| 3 | all `Succeeded` | a `Pending`/`Installing` CSV — operators re-reconciling, give it a few min |
| 4 | `Ready` | DSC still reconciling after restart — wait |
| 5 | InferenceService `READY=True`, pod **2/2 Running** (and *only* one) | `0/2`/`1/2` = reloading + recompiling (~2–3 min, image cached); `Pending` = GPU not back (see #2); many `Init:ContainerStatusUnknown` = node-lost ghosts (clean up, below) |
| 6 | `overallStatus=Ready`, URL→served model, `contextWindowSize` = the runtime's `--max-model-len`, app-server **3/3** | `NotReady` usually just waiting on the model pod (#5); `contextWindowSize` ≠ `--max-model-len` → fix below |
| 7 | JSON listing `"id":"<model>"` | endpoint not up → model pod isn't `2/2` (see #5) |

## Full pass/fail script (optional)

Same checks, but auto-detects the model and prints a ✓/✗ per layer with a final verdict. Paste it, or save as `scripts/health-check.sh` and `chmod +x`:

```bash
#!/usr/bin/env bash
# Verify a self-hosted OpenShift Lightspeed install is fully up. Read-only.
set -uo pipefail
LS_NS="openshift-lightspeed"; LLM_NS="lightspeed-llm"
if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else G=; Y=; R=; C=; N=; fi
pass(){ printf "%s\n" "${G}  ✓${N} $*"; }; fail(){ printf "%s\n" "${R}  ✗${N} $*"; FAILED=1; }
warn(){ printf "%s\n" "${Y}  !${N} $*"; }; head(){ printf "\n%s\n" "${C}==> $*${N}"; }
FAILED=0
oc whoami >/dev/null 2>&1 || { echo "${R}not logged in (oc).${N}"; exit 1; }

head "1. GPU node"
oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -qE '^[1-9]' \
  && pass "schedulable GPU capacity" || fail "no node exposes nvidia.com/gpu"

head "2. Operators (CSVs Succeeded)"
for kv in "$LS_NS:lightspeed-operator" "openshift-nfd:nfd" "nvidia-gpu-operator:gpu-operator" "redhat-ods-operator:rhods-operator"; do
  ns="${kv%%:*}"; pfx="${kv##*:}"
  oc get csv -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -E "^${pfx}.* Succeeded$" >/dev/null && pass "${pfx} Succeeded" || fail "${pfx} not Succeeded in ${ns}"
done

head "3. DataScienceCluster"
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Ready \
  && pass "default-dsc Ready" || fail "default-dsc not Ready"

head "4. Model serving"
MODEL="$(oc get inferenceservice -n "$LLM_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -z "$MODEL" ]; then fail "no InferenceService in ${LLM_NS}"; else
  oc get inferenceservice "$MODEL" -n "$LLM_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True \
    && pass "InferenceService ${MODEL} Ready" || fail "InferenceService ${MODEL} not Ready"
  running="$(oc get pods -n "$LLM_NS" --no-headers 2>/dev/null | grep -c ' 2/2 .*Running')"
  other="$(oc get pods -n "$LLM_NS" --no-headers 2>/dev/null | grep -vc ' 2/2 .*Running')"
  [ "${running:-0}" -ge 1 ] && pass "predictor pod 2/2 Running" || fail "no predictor pod 2/2 Running"
  [ "${other:-0}" -gt 0 ] && warn "${other} non-running predictor pod(s) — node-lost ghosts; clean up (below)"
fi

head "5. OLSConfig"
overall="$(oc get olsconfig cluster -o jsonpath='{.status.overallStatus}' 2>/dev/null)"
[ "$overall" = "Ready" ] && pass "overallStatus Ready" || fail "overallStatus=${overall:-<none>}"
url="$(oc get olsconfig cluster -o jsonpath='{.spec.llm.providers[0].url}' 2>/dev/null)"
ctx="$(oc get olsconfig cluster -o jsonpath='{.spec.llm.providers[0].models[0].contextWindowSize}' 2>/dev/null)"
dm="$(oc get olsconfig cluster -o jsonpath='{.spec.ols.defaultModel}' 2>/dev/null)"
printf "    url=%s  defaultModel=%s  contextWindowSize=%s\n" "$url" "$dm" "$ctx"
if [ -n "$MODEL" ]; then
  case "$url" in *"${MODEL}-predictor"*) pass "provider URL points at ${MODEL}";; *) fail "provider URL != served model ${MODEL}";; esac
  [ "$dm" = "$MODEL" ] || warn "defaultModel (${dm}) != served model (${MODEL})"
  mml="$(oc get inferenceservice "$MODEL" -n "$LLM_NS" -o jsonpath='{range .spec.predictor.model.args[*]}{@}{"\n"}{end}' 2>/dev/null | sed -n 's/^--max-model-len=//p')"
  [ -n "$mml" ] && [ -n "$ctx" ] && { [ "$ctx" = "$mml" ] && pass "contextWindowSize matches --max-model-len ($ctx)" \
    || fail "contextWindowSize ($ctx) != --max-model-len ($mml) — long prompts get rejected"; }
fi
oc get pods -n "$LS_NS" --no-headers 2>/dev/null | grep app-server | grep -q Running \
  && pass "lightspeed-app-server Running" || fail "lightspeed-app-server not Running"

head "6. Endpoint reachable in-cluster"
[ -n "$MODEL" ] && { oc run lshealth-$$ --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -n "$LLM_NS" -- \
  curl -s -m 8 "http://${MODEL}-predictor.${LLM_NS}.svc.cluster.local:8080/v1/models" 2>/dev/null | grep -q "\"id\":\"${MODEL}\"" \
  && pass "endpoint answers /v1/models as ${MODEL}" || fail "endpoint not reachable (model pod not 2/2 yet?)"; }

echo
[ "$FAILED" -eq 0 ] && printf "%s\n" "${G}All checks passed — Lightspeed is up.${N}" \
  || printf "%s\n" "${Y}Some checks failed — see Common fixes in docs/HEALTH_CHECK.md.${N}"
exit $FAILED
```

## Common fixes after a restart

Config survives shutdown; pods and the GPU node don't. The usual cleanups:

**Node-lost ghost predictor pods** (`Init:ContainerStatusUnknown` / `Error`). The Deployment wants 1 replica; the running `2/2` pod satisfies it, so force-delete the rest (they won't respawn):

```bash
oc get pods -n lightspeed-llm --no-headers \
  | awk '$3!="Running"{print $1}' \
  | xargs -r oc delete pod -n lightspeed-llm --force --grace-period=0
```

**`contextWindowSize` drifted away from the model's `--max-model-len`** (e.g. shows 32768 while the model serves 24576). They must match or vLLM rejects long prompts:

```bash
MODEL=$(oc get inferenceservice -n lightspeed-llm -o jsonpath='{.items[0].metadata.name}')
oc patch olsconfig cluster --type=merge -p \
  '{"spec":{"llm":{"providers":[{"name":"rhoai","type":"rhoai_vllm","credentialsSecretRef":{"name":"rhoai-vllm-token"},"url":"http://'"$MODEL"'-predictor.lightspeed-llm.svc.cluster.local:8080/v1","models":[{"name":"'"$MODEL"'","contextWindowSize":24576,"parameters":{"maxTokensForResponse":1024}}]}]}}}'
```

**App-server serving stale config** after the model recovered (`overallStatus` stuck `NotReady`, or "connection error" though the endpoint curls fine):

```bash
oc rollout restart deploy/lightspeed-app-server -n openshift-lightspeed
```

See the README **Troubleshooting (self-hosted)** section for the deeper failure modes (KV-cache OOM, tool-calling flags, headless endpoint port).

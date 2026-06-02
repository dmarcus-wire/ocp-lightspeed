# Demo walkthrough

The story: run **OpenShift Lightspeed** two ways — against a **hosted SaaS** model and against a
**self-hosted, Red Hat–validated** model — and show that the *experience* (Ask, Troubleshooting,
approval gate) is identical while the *trade-offs* are opposite. Then the lessons learned from
standing it up for real.

> One `OLSConfig` exists at a time (it's cluster-scoped, named `cluster`), so you stand up one
> pattern, demo it, switch, and demo the other. That switch *is* the punchline.

Detailed reference (prereqs, model matrix, troubleshooting) lives in the [README](../README.md);
post-restart recovery in [HEALTH_CHECK.md](HEALTH_CHECK.md). A CLI smoke test and extra prompts are in
the [Appendix](#appendix--cli-smoke-test--more-prompts) below.

---

## 0. Provision

**Prereqs:** an OpenShift-on-AWS cluster (4.16+) + cluster-admin; the Web Terminal (console `>_`
icon); for self-hosted, GPU quota for one `g6.2xlarge` (1× L4). See
[Keep your clone across sessions](../README.md#keep-your-clone-across-sessions-optional) so you don't
re-clone every time.

```bash
git clone https://github.com/dmarcus-wire/ocp-lightspeed.git && cd ocp-lightspeed
./provision.sh            # guided: pick pattern, model, features
```

Always verify health before demoing — especially after a sandbox restart:

```bash
oc get olsconfig cluster -o jsonpath='{.status.overallStatus}{"\n"}' -w  # want: Ready
```

---

## 1. SaaS — Lightspeed → your hosted OpenAI model

The fast path: no GPUs, a capable model in minutes. **Trade-off to call out: your prompts — and in
Troubleshooting mode, the live cluster data the tools read — leave the cluster for OpenAI.**

**Connect** (needs your own API key — see [Using your own OpenAI key](../README.md#using-your-own-openai-key-saas)):

```bash
./provision.sh --switch --pattern saas --openai-key sk-... --features agent-troubleshooting --yes
```

Verify the model you are running
```bash
oc get olsconfig cluster -o jsonpath='{.spec.ols.defaultModel}{"\n"}'
```

Then in the console (Lightspeed icon), run the three tests:

(Optional - monitor logs while prompting)

For SaaS there's no model pod to watch (OpenAI is off-cluster) — everything happens in the app-server, and the OpenAI calls show up inline as httpx requests.

`oc logs -n openshift-lightspeed deploy/lightspeed-app-server -c lightspeed-service-api -f --tail=20`

For the Troubleshooting tests, also tail the MCP server in a second pane — it shows the live cluster reads the agent makes:

`oc logs -n openshift-lightspeed deploy/lightspeed-app-server -c openshift-mcp-server -f --tail=20`

For the write test, first spin up a throwaway deployment to scale — the agent refuses to scale
operator-managed deployments like `lightspeed-console-plugin` (it sees the operator owns them and
declines), so give it a plain target:

```bash
oc create deployment demo-scale -n openshift-lightspeed \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- sleep infinity
```

1. **Ask** — *"What is an OpenShift Route vs an Ingress?"* → doc-grounded answer.
2. **Troubleshoot** — *"List the pods in namespace openshift-lightspeed and their restart counts."* → it
   calls the Kubernetes MCP tools and names your real pods.
3. **Write (where low-tier SaaS hits its ceiling)** — *"Using your cluster tools, scale the deployment
   demo-scale in openshift-lightspeed to 2 replicas."* On a **low usage tier**, this is exactly where
   hosted SaaS shows its limits: `gpt-4o` trips the **30k-TPM rate limit** (the tool-catalog-heavy
   agent loop), and `gpt-4o-mini` **loops on read tools and narrates the action without ever
   committing the write** — so the scale often doesn't land (`oc get deploy demo-scale … desired=1`)
   and no approval card appears. That ceiling **is the segue to self-hosted** (no per-minute caps,
   your own model) — the write + approval is the §2 payoff. Clean up: `oc delete deployment demo-scale -n openshift-lightspeed`.

**Point made:** Ask and Troubleshoot are fast and impressive — but the write test shows a low-tier
hosted account throttling (gpt-4o) or hesitating (mini), and *every* token and cluster read went to a
hosted API. That's the cue to switch to self-hosted.

---

## 2. Self-hosted — Lightspeed → a Red Hat–validated model on vLLM

Same three tests, but the model runs on *your* GPU and **nothing leaves the cluster**. This is also
where model choice becomes the story.

**Connect** (builds the GPU + serving stack; ~30–45 min first time):

```bash
./provision.sh --switch --pattern selfhosted --model gpt-oss-20b --instance g6.2xlarge \
  --features agent-troubleshooting --vllm-token novalue --yes
```

Keep the agent loop visible while you demo — this is what *proves* the model is calling cluster tools:

```bash
oc logs -n openshift-lightspeed deploy/lightspeed-app-server -c lightspeed-service-api -f --tail=5
```

1. **Ask — on `gpt-oss-20b`.** *"Write the YAML for a HorizontalPodAutoscaler targeting 70% CPU on a
   deployment named web."* → a correct manifest, generated entirely on your L4. gpt-oss-20b is a
   strong single-shot reasoning model and Ask mode shines.

2. **(Optional) Show why model choice matters — the fumble.** Skip for the happy path; include it for
   a great "here's the trap" test. In Troubleshooting mode, ask the restart-count prompt *on
   gpt-oss-20b* and watch the loop: `model_finished_without_tools` with an **empty answer** — it reads
   one tool then bails. Its reasoning/harmony format doesn't drive OLS's tool loop on this vLLM build.
   That's the live motivation for switching models.

3. **Switch to the validated, tool-tuned model.** Single L4 = one model at a time, so free the GPU
   first:

   ```bash
   oc delete inferenceservice gpt-oss-20b -n lightspeed-llm
   ./provision.sh --switch --pattern selfhosted --model granite-3.3-8b-instruct \
     --instance g6.2xlarge --features agent-troubleshooting --vllm-token novalue --yes
   ```

4. **Troubleshoot — on granite.** Restart-count prompt in Troubleshooting mode → granite issues real
   `pods_list` calls (watch the loop) and answers with your live pods.

5. **Write / approval test — on granite.** Reuse the throwaway target from §1 (recreate if it's gone:
   `oc create deployment demo-scale -n openshift-lightspeed --image=registry.access.redhat.com/ubi9/ubi-minimal -- sleep infinity`),
   then: *"Using your cluster tools, scale the deployment demo-scale in openshift-lightspeed to 2
   replicas."* Self-hosted has **no rate limits**, so the agent can run the full multi-step loop
   without throttling — the ceiling SaaS hit in §1. Watch the loop for a **write** tool call; if the
   model commits it, `tool_annotations` gates it with an **Approve/Deny** card (whether the card
   renders depends on the model actually issuing the write — verify with your model). Don't target an
   operator-managed deployment like `lightspeed-console-plugin` — the agent correctly refuses those.

**Model recommendation (the lesson):** for **Troubleshooting/agent mode use `granite-3.3-8b-instruct`**
— Red Hat's validated, tool-tuned model that drives function-calling reliably. Keep **`gpt-oss-20b`
for the Ask / "self-hosted reasoning model" story**. It's not about size — bigger reasoning models
hit the same harness mismatch and don't fit one L4. See the README ["Which model?"](../README.md#model-matrix-self-hosted).

**Point made:** same Ask/Troubleshoot experience as SaaS, but with **no token billing, no per-minute
rate limits, and nothing leaving the cluster** — it all ran on your single GPU, on a Red Hat–validated
model you control.

---

## Business value — the "why" behind self-hosting

Both patterns give the same Lightspeed experience; self-hosting is the choice you make for control,
cost, and trust. The four pillars:

1. **Validated, secured models — not raw open weights.** Red Hat ships models as **ModelCar** OCI
   images from a curated catalog: known provenance, scanned, and supportable through a lifecycle —
   versus pulling arbitrary open weights off the internet (unvetted supply chain, license and CVE
   risk). You run an *enterprise-supported* model, not a science project.
2. **Cost control on AI for operations.** Hosted is pay-per-token; self-hosted is a **flat GPU
   $/hr**. For the steady, high-volume workload of running the cluster (the Lightspeed use case
   itself), self-hosting caps spend instead of metering every query. (Quantify it below.)
3. **You control the model and the data — no forced changes.** SaaS vendors deprecate models, shift
   behavior, pricing, and terms on *their* schedule. Self-hosting pins a validated model and keeps
   prompts **and live cluster data** on-cluster (compliance, air-gap, residency). You migrate when
   *you* choose — not when a provider sunsets an endpoint.
4. **Low-risk, high-value on-ramp.** Cluster troubleshooting is a high-value, low-blast-radius first
   AI use case. Standing it up self-hosted also builds the GPU + model-serving **platform** — which
   then unlocks other on-cluster AI workloads without starting from zero.

### Quantify the cost story (token capture)

Costs have **opposite shapes**: hosted is *variable* (tokens × price); self-hosted is *fixed* (GPU
$/hr, any volume). Measure the demo's actual tokens to draw the break-even.

**Self-hosted — tokens served (vLLM `/metrics`).** Paste this helper once, then call it before and
after a run; the delta is what the demo consumed:

```bash
# cumulative prompt/generation/total tokens the model has served
vllm_tokens() {
  local m; m=$(oc get inferenceservice -n lightspeed-llm -o jsonpath='{.items[0].metadata.name}')
  oc run tok-snapshot --rm -i --restart=Never -n lightspeed-llm \
     --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
     curl -s "http://${m}-predictor.lightspeed-llm.svc.cluster.local:8080/metrics" 2>/dev/null \
   | awk '/^vllm:prompt_tokens_total/{p=$NF} /^vllm:generation_tokens_total/{g=$NF} END{printf "%.0f %.0f %.0f\n",p,g,p+g}'
}

read BP BG BT < <(vllm_tokens)     # snapshot BEFORE the demo
#   ... run your Ask / Troubleshoot / approval prompts in the console ...
read AP AG AT < <(vllm_tokens)     # snapshot AFTER
echo "demo used: prompt=$((AP-BP)) generation=$((AG-BG)) total=$((AT-BT)) tokens"
```

The counters are cumulative since the pod started, so don't restart the predictor mid-measurement.
**Cost is the GPU, not the tokens** — a `g6.2xlarge` is a flat ~$/hr (check current AWS pricing),
your entire LLM bill no matter how many tokens you push.

**Hosted — tokens & dollars (OpenAI).** Every API response carries a `usage` block (`prompt_tokens`,
`completion_tokens`, `total_tokens`); the running bill and totals are at platform.openai.com →
**Usage** (cap it under Settings → **Limits**). **Cost = tokens × model price** — linear with use.

**The break-even slide.** Flat GPU $/hr vs tokens × hosted-price. Below the crossover SaaS is cheaper
and starts in minutes; above it — steady, high-volume, or data-sensitive workloads — self-hosting
wins on cost *and* keeps data on-cluster. Take the measured token delta, multiply by the hosted
price, annualize, and compare to the GPU's yearly cost: the business case in one chart.

> Want it continuous? Enable user-workload monitoring and the `vllm:*` counters scrape into
> Prometheus — graph tokens/sec and cumulative tokens in the console over time.

---

## Resetting between runs & rough timing

**Rough timing** (approximate — *verify on your cluster*; first-time is dominated by image pulls):

| Step | First time | Repeat (warm) |
| --- | --- | --- |
| Provision self-hosted (cold cluster) | ~30–45 min | — |
| Provision SaaS | ~3–5 min | ~1–2 min |
| Switch self-hosted → SaaS | ~1–2 min | ~1–2 min |
| Switch SaaS → self-hosted (GPU stack already up) | ~8–12 min (model pull) | ~3–4 min (image cached) |
| Switch model (e.g. gpt-oss → granite) | ~8–12 min (pull) | ~3–4 min |
| app-server reload after a patch | ~30–60 s | — |
| Ask query | ~5–30 s | — |
| Agent (multi-step) query | ~30 s–2 min | — |

**Reset to a clean state** between runs or before handing off:

- Flip patterns: `./provision.sh --switch` (deletes the OLSConfig, applies the other).
- Free the GPU by removing a model you switched away from: `oc delete inferenceservice <name> -n lightspeed-llm`.
- Clear config but keep the infra: `./provision.sh --uninstall` (removes OLSConfig + Route).
- After a sandbox restart: run [HEALTH_CHECK.md](HEALTH_CHECK.md) (clean ghost pods, re-verify `contextWindowSize`).
- Full teardown (destructive): `make uninstall-infra`.

---

## 3. Lessons learned (what it took to make this real)

Each of these was a live failure we diagnosed; the fixes are committed in the repo, and this list is
the reference for what broke and why.

### GPU & infra

- **Predictor stuck `Pending`** — `g6.xlarge` (4 vCPU/16 GiB) is too small once daemonsets are
  counted. Use `g6.2xlarge`; size requests below node-allocatable.
- **Editing a MachineSet doesn't replace nodes** — to resize the GPU node you must delete the old
  machine so the set recreates it.
- **CPU vLLM image on a GPU box** — naive "first vllm image" picked `…vllm-cpu…`; the GPU sat idle.
  Resolve a CUDA image, never the CPU one.

### Serving & model fit (single L4, 24 GB)

- **KServe webhook race** — applying the model before `kserve-webhook-server-service` had endpoints
  failed with "no endpoints available." Wait for the webhook.
- **KV-cache OOM at 32k** — a full **bf16** 8B (granite, ~15 GiB) leaves only ~4.3 GiB KV; 32k needs
  ~5. Default to `--max-model-len=24576` + `--gpu-memory-utilization=0.95`. (Quantized gpt-oss MXFP4
  ~13.7 GiB had more room — quantization changes the math.)
- **Single-GPU rollout deadlock** — a rolling update can't place the new pod (the old one holds the
  only GPU). Use `deploymentStrategy: Recreate`.

### OLS ↔ model wiring

- **Headless predictor Service** — the cluster-local DNS resolves straight to the pod, so the
  provider URL must use the real container port (`:8080`), not `:80`.
- **`contextWindowSize` must match `--max-model-len`** — a mismatch lets OLS build prompts vLLM
  rejects. (It also drifted back to 32k after a restart — worth checking in the health check.)
- **DNS-invalid model names** — KServe rejects dots, so `granite-3.3-8b-instruct` becomes object name
  `granite-3-3-8b-instruct`; the dotted form is only the modelcar OCI tag.
- **`defaultModel` on switch** — switching `--model` must also update `ols.defaultModel`, or OLS
  points at a model that's no longer served.

### Agent-mode behavior

- **"Prompt is too long"** — agent mode injects the ~6k-token MCP tool catalog; the context window
  must hold tools + prompt + answer (≈10k), so 8k overflowed. 24k clears it.
- **Tool-calling must be enabled per model** — vLLM 400s on `tool_choice=auto` without
  `--enable-auto-tool-choice` + the *right* `--tool-call-parser`. The parser must match the model's
  emitted format: the **granite-3.3 modelcar emits Hermes-style `<tool_call>` tags, so it needs
  `hermes`, not `granite`** — with the wrong parser the call leaks into the chat as raw JSON and never
  executes. (gpt-oss's runtime enables tools implicitly, which is why it *accepted* tools but still
  fumbled them.)
- **Console hangs on `...`** — a verbose model can run past the console's patience; cap answers with
  `maxTokensForResponse`.
- **Model choice dominates agent reliability** — gpt-oss-20b bails (empty answers); granite drives
  the loop. Validated/tool-tuned beats bigger.
- **SaaS rate-limits agent mode** — a `429 Too Many Requests` (distinct from the billing
  `insufficient_quota`) is a per-minute **rate limit**. New OpenAI accounts start in a low usage tier
  (requests/tokens-per-minute), and agent mode fires *many sequential* chat/completions calls — one
  per tool round — which trips the cap. The client retries with backoff, so it eventually completes
  but is slow and janky. The tier rises with usage/payment history (or request an increase). **Self-
  hosted has no per-minute cap** (it's your GPU) — a concrete pillar-2/4 point.

### Ops

- **Ephemeral web terminal** — `/home/user` is wiped on idle; enable `persistUserHome` (or use the
  clone-or-pull one-liner) so you don't re-clone.
- **Sandbox shuts down nightly** — config persists in etcd; pods and the GPU node recover on their
  own. Run [HEALTH_CHECK.md](HEALTH_CHECK.md), clean ghost pods, re-verify `contextWindowSize`.

---

## Appendix — CLI smoke test & more prompts

### Smoke test (CLI) — prove the model serves before blaming the console

You have no Route, so run these *inside* the cluster. If they work but the console doesn't, the issue
is OLSConfig wiring, not the model.

```bash
M=$(oc get inferenceservice -n lightspeed-llm -o jsonpath='{.items[0].metadata.name}')

# 1) model registered?
oc run t1 --rm -i --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -n lightspeed-llm -- \
  curl -s "http://${M}-predictor.lightspeed-llm.svc.cluster.local:8080/v1/models"

# 2) a real completion (end-to-end inference)?
oc run t2 --rm -i --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -n lightspeed-llm -- \
  curl -s "http://${M}-predictor.lightspeed-llm.svc.cluster.local:8080/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${M}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":64}"
```

Expect a JSON model list (note `max_model_len` matches `infra/60`), then a completion whose `content`
is `OK`. Give a *reasoning* model (gpt-oss) enough `max_tokens` (64) to finish reasoning **and** emit
content — too low leaves `content` empty (`finish_reason:"length"`).

### More prompts to try

**Ask mode** (docs knowledge, no cluster access):

- *"What is the difference between a Route and an Ingress in OpenShift?"*
- *"How do I expose a Deployment as a Service on port 8080?"*

**Troubleshooting mode** (live cluster reads via MCP), easiest → hardest:

- *"List the namespaces that have pods in a non-Running state right now."*
- *"In namespace openshift-lightspeed, are all containers in the lightspeed-app-server pod ready?"*
- *"List all pods in openshift-lightspeed with their restart counts; for any over 3, summarize the likely cause from their events."*

A good answer names **specific objects from your cluster** — that's proof the MCP read path ran, not
just the model's training knowledge.

## Troubleshooting (self-hosted)

> **After a sandbox restart?** Run the [health check](docs/HEALTH_CHECK.md) — it verifies each layer
> (GPU node → operators → DSC → model → OLSConfig → endpoint) and lists the usual post-restart fixes
> (ghost pods, `contextWindowSize` drift, app-server reload).

`provision.sh` is idempotent — for most failures, fix the cause and re-run with the same flags;
completed steps re-verify in seconds. Specific gotchas:

**Predictor stuck `Pending` — "Insufficient cpu/memory".** The GPU node is too small for the
model's requests (see the matrix note above). Use a bigger instance (`--instance g6.2xlarge`).
The default is already `g6.2xlarge`.

**Resizing the GPU node.** Editing a MachineSet does **not** replace running nodes — the template
only applies to *new* machines. To swap an existing GPU node to a bigger instance, change the type
and delete the old machine so the set recreates it (then wait ~15-25 min for the NVIDIA driver):

```bash
GPU_MS=$(oc get machineset -n openshift-machine-api -o name | grep -- '-gpu' | head -1)
oc patch $GPU_MS -n openshift-machine-api --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/providerSpec/value/instanceType","value":"g6.2xlarge"}]'
oc delete machine -n openshift-machine-api \
  -l machine.openshift.io/cluster-api-machineset=$(basename $GPU_MS)
watch "oc get machines -n openshift-machine-api | grep gpu; \
  oc get nodes -o custom-columns=NAME:.metadata.name,GPU:'.status.allocatable.nvidia\.com/gpu'"
```

**`InferenceService` not `Ready`.** Check `oc logs -n lightspeed-llm -l serving.kserve.io/inferenceservice=<model>`
(add `--previous` if it's crash-looping). KV-cache OOM at startup → see the crash-loop entry below.
vLLM "unsupported model / unknown architecture" → the RHOAI runtime is too old for that model; fall
back to `--model granite-3.3-8b-instruct` (known-good, still tool-calling capable).

**OLSConfig `NotReady`, `ApiReady=False`, app-server `2/3`, logs show "LLM connection error".**
The app-server can't reach the model. KServe RawDeployment creates a **headless** predictor Service
(`ClusterIP: None`), so the cluster-local DNS name resolves straight to the pod and only the
container's real port (`8080`) answers — the Service's `80 → 8080` mapping is bypassed, and
`InferenceService .status.url` omits the port. `provision.sh` now builds the provider URL as
`http://<model>-predictor.<ns>.svc.cluster.local:8080/v1`. To verify reachability:

```bash
oc run curl-test --rm -i --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -n lightspeed-llm -- \
  curl -s -m 5 -o /dev/null -w "http=%{http_code}\n" \
  http://<model>-predictor.lightspeed-llm.svc.cluster.local:8080/v1/models   # want: http=200
```

**CPU vLLM image picked on a GPU cluster.** If `oc get servingruntime vllm-runtime -n lightspeed-llm
-o jsonpath='{.spec.containers[0].image}'` shows `...vllm-cpu...`, the GPU is reserved but unused and
the model crawls. `provision.sh` resolves a CUDA image (`...vllm-cuda...`) and never the CPU one.

**Console hangs on `...` / answer never renders.** A verbose or reasoning model (e.g. gpt-oss-20b)
can generate for minutes, and OLSConfig exposes no LLM-query timeout. Cap the answer so it returns
in time via `models[].parameters.maxTokensForResponse` (default `1024` here). Confirm the model
itself is fine by calling it directly — if `choices[0].message.content` is populated, the model
works and the issue is OLS-side timing/rendering:

```bash
oc run t1 --rm -i --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -n lightspeed-llm -- \
  curl -s http://gpt-oss-20b-predictor.lightspeed-llm.svc.cluster.local:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-oss-20b","messages":[{"role":"user","content":"say OK"}],"max_tokens":10}'
```

**"Prompt is too long" in Troubleshooting/agent mode.** Agent mode injects the Kubernetes MCP
**tool catalog** (~5.8k tokens) into every prompt. The usable budget is:

```text
prompt budget = contextWindowSize × (1 − toolBudgetRatio) − maxTokensForResponse
```

With an 8192 window that's only `8192 × 0.5 − 1024 = 3072` — smaller than the tool catalog, so
requests fail. The window must hold tools + prompt + answer (~9-10k). Raise **both** the runtime and
OLS (they're separate objects — a bigger served context does nothing until OLS knows the window
grew), then restart the app-server. `provision.sh` defaults to `--max-model-len=24576` /
`contextWindowSize=24576` (budget ~11k — clears the tool catalog), which fits a single L4. To set it
manually:

```bash
# 1) runtime context (must fit the KV cache — see the OOM note below)
oc patch inferenceservice <model> -n lightspeed-llm --type=merge -p \
  '{"spec":{"predictor":{"model":{"args":["--served-model-name=<model>","--max-model-len=24576","--gpu-memory-utilization=0.95"]}}}}'
# 2) OLS: match the window
oc patch olsconfig cluster --type=merge -p \
  '{"spec":{"llm":{"providers":[{"name":"rhoai","type":"rhoai_vllm","credentialsSecretRef":{"name":"rhoai-vllm-token"},"url":"http://<model>-predictor.lightspeed-llm.svc.cluster.local:8080/v1","models":[{"name":"<model>","contextWindowSize":24576,"parameters":{"maxTokensForResponse":1024}}]}]}}}'
# 3) reload the app-server
oc rollout restart deploy/lightspeed-app-server -n openshift-lightspeed
```

Override the defaults with the `CONTEXT_WINDOW` / `MAX_RESPONSE_TOKENS` env vars.

**Predictor crash-loops with `ValueError: … KV cache memory` at startup.** The context is too large
for the GPU. KServe shows `RESTARTS` climbing and the *previous* container log
(`oc logs … -c kserve-container --previous`) ends in `To serve … max seq len (N), X GiB KV cache is
needed, which is larger than the available KV cache memory (Y GiB)`. **Full bf16 models are bigger
than quantized ones** — granite-3.3-8b (bf16, ~15 GiB) leaves only ~4.3 GiB for KV on a 24 GB L4, so
32k (needs ~5 GiB) won't fit, while gpt-oss-20b (MXFP4, ~13.7 GiB) does. vLLM prints an "estimated
maximum model length" in the error — set `--max-model-len` below it (24576 is the safe default here)
and add `--gpu-memory-utilization=0.95`, then drop `contextWindowSize` to match.

**New predictor pod stuck `Pending` after a model/config change — "Insufficient nvidia.com/gpu".**
A single-GPU rolling update deadlocks: the surge brings the new pod up before the old releases the
only GPU. The predictor uses `deploymentStrategy: Recreate` (set in `infra/60`) so the old pod is
torn down first. If a live update is already wedged, free the GPU by deleting the old (Running) pod:
`oc delete pod -n lightspeed-llm <old-predictor-pod>`.

**Want a faster, friction-free model?** A 20B reasoning model on a single L4 is slow for interactive
chat and tight on context for agent mode. `--model granite-3.3-8b-instruct` has a large context, is
~2-3× faster on an L4, and still does tool-calling — the dependable choice for live demos. Keep
gpt-oss-20b for the "self-hosted reasoning model" story when latency isn't on the clock.
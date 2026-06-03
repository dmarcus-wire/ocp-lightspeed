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

**Health check** — wait for `Ready` before prompting (SaaS converges in ~1–3 min):

```bash
oc get olsconfig cluster -o jsonpath='{.status.overallStatus}' -w   # Ctrl-C when it shows: Ready
```

Then confirm which model is active:

```bash
oc get olsconfig cluster -o jsonpath='{.spec.ols.defaultModel}{"\n"}'
```

**Monitor (optional, 2nd terminal)** — SaaS has no model pod (OpenAI is off-cluster); everything runs
in the app-server, and OpenAI calls appear inline as `httpx` requests. The MCP-server pane shows the
live cluster reads during the Troubleshooting/write tests:

```bash
oc logs -n openshift-lightspeed deploy/lightspeed-app-server -c lightspeed-service-api -f --tail=20
oc logs -n openshift-lightspeed deploy/lightspeed-app-server -c openshift-mcp-server   -f --tail=20
```

**Set up the write test** — a throwaway deployment to scale (the agent refuses operator-managed ones
like `lightspeed-console-plugin`, which it sees are reconciled and declines):

```bash
oc create deployment demo-scale -n openshift-lightspeed \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- sleep infinity
```

Then in the console (Lightspeed icon), run the three tests:

1. **Ask** (how-to) — *"How do I expose my application to users outside the cluster?"* → doc-grounded
   answer (Route/Ingress), no cluster access needed.
2. **Troubleshoot** (their cluster) — *"Is everything in the `openshift-lightspeed` namespace healthy
   right now?"* → it calls the Kubernetes MCP tools and reports on your real workloads.
3. **Write (where low-tier SaaS hits its ceiling)** — *"Scale my demo-scale app in openshift-lightspeed
   to 2 replicas."* On a **low usage tier**, this is exactly where
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

**Health check** — the build is done when the predictor is serving (the long poles are the GPU node
coming up, then the model load):

```bash
oc get pods -n lightspeed-llm -w                                    # want: predictor 2/2 Running
oc get olsconfig cluster -o jsonpath='{.status.overallStatus}'      # want: Ready
```

**Monitor (optional, 2nd terminal)** — the agent loop is what *proves* the model is calling cluster
tools (read it live as you prompt):

```bash
oc logs -n openshift-lightspeed deploy/lightspeed-app-server -c lightspeed-service-api -f --tail=5
```

Run the tests below. **After the granite switch (step 3), re-run the Health check before testing again.**

1. **Ask — on `gpt-oss-20b`.** *"Write the YAML for a HorizontalPodAutoscaler targeting 70% CPU on a
   deployment named web."* → a correct manifest, generated entirely on your L4. gpt-oss-20b is a
   strong single-shot reasoning model and Ask mode shines.

2. **(Optional) Show why model choice matters — the fumble.** Skip for the happy path; include it for
   a great "here's the trap" test. It's the **same write prompt you'll use on granite in step 5**, so
   it sets up a clean before/after. Make sure `demo-scale` exists first (created in §1; recreate with
   the command in step 5 if you skipped §1), then in Troubleshooting mode ask:
   > *"Scale my demo-scale app in openshift-lightspeed to 2 replicas."*

   Watch the loop: gpt-oss reads a tool, then `model_finished_without_tools` with an **empty answer** —
   it never commits the write, so the scale doesn't land (`oc get deploy demo-scale … desired=1`) and
   no approval card appears. Its reasoning/harmony format doesn't drive OLS's tool loop on this vLLM
   build. That's the live motivation for switching — the *same* prompt succeeds on granite in step 5.

3. **Switch to the validated, tool-tuned model.** Single L4 = one model at a time, so free the GPU
   first:

   ```bash
   oc delete inferenceservice gpt-oss-20b -n lightspeed-llm
   ./provision.sh --switch --pattern selfhosted --model granite-3.3-8b-instruct \
     --instance g6.2xlarge --features agent-troubleshooting --vllm-token novalue --yes
   ```

   **Confirm the switch completed before testing.** `--switch` deletes the OLSConfig first and only
   re-creates it once the new model is `Ready` — so if the script is interrupted (e.g. the cluster
   restarts mid-switch), you're left with **no OLSConfig**, the app-server torn down, and the console
   showing the "Get started" promo instead of chat. Verify all three came back:

   ```bash
   oc get olsconfig cluster -o jsonpath='overall={.status.overallStatus} model={.spec.ols.defaultModel}{"\n"}'
   #   want: overall=Ready model=granite-3-3-8b-instruct   (NOT "cluster not found")
   oc get pods -n openshift-lightspeed     # lightspeed-app-server back, 3/3 Running
   oc get pods -n lightspeed-llm           # granite-3-3-8b-instruct-predictor 2/2 Running
   ```

   If the OLSConfig is missing or still says gpt-oss-20b, the switch didn't finish — just re-run the
   command above (idempotent: it waits for granite, then re-creates the OLSConfig). Then hard-refresh
   the console.

4. **Troubleshoot — on granite (customer-voice function tests).** Phrase these the way a customer in a
   POC actually would — outcome-oriented, about *their* cluster — not like `oc` commands. They exercise
   the read-only MCP tools; each is anchored to a real object so there's a verifiable answer:
   > *"Is everything in the openshift-lightspeed namespace healthy right now?"*
   > *"My demo-scale app in openshift-lightspeed — is it running, and how many replicas does it have?"*
   > *"Are any apps in my cluster crash-looping or stuck?"*
   > *"Something looks off with the granite model in lightspeed-llm — can you check it and tell me what's wrong?"*

   **The killer POC moment — break it, then ask why.** Deliberately break the app, then ask in plain
   language (the agent reads the events and explains the `ImagePullBackOff`):

   ```bash
   oc set image deployment/demo-scale ubi-minimal=registry.access.redhat.com/ubi9/does-not-exist:nope -n openshift-lightspeed
   ```

   > *"My demo-scale app in openshift-lightspeed stopped working — can you tell me why?"*

   (Reset after: `oc set image deployment/demo-scale ubi-minimal=registry.access.redhat.com/ubi9/ubi-minimal -n openshift-lightspeed`.)

   **Did it actually execute? (the pass/fail).** Tail the loop and read the answer:
   - **Pass** — `outcome=after_tool_execution` with **`tool_results` > 0**, and the answer names **real
     objects** (actual pod names, conditions, counts) — proof the MCP read path ran.
   - **Fail (advice)** — `tool_results=0` and a generic *"use `oc get pods …`"* answer: the model
     didn't call the tool.
   - ⚠️ **OLS-version-sensitive.** These executed cleanly on operator **v1.0.x**; on **v1.1.0** granite
     tends to return the advice form (the regression in Lessons learned). If you get advice with tools
     attached (`tool_defs` > 0, `tool_results=0`), it's the OLS version — not your prompt or config.

5. **Write / approval test — on granite (best-effort).** Recreate the target if gone
   (`oc create deployment demo-scale -n openshift-lightspeed --image=registry.access.redhat.com/ubi9/ubi-minimal -- sleep infinity`),
   then: *"Scale my demo-scale app in openshift-lightspeed to 2 replicas."* **If** the model commits a
   write tool call, `tool_annotations` gates it with an
   **Approve/Deny** card. This is the **least reliable** beat: small models often **advise instead of
   acting** on mutating operations, and v1.1.0 doesn't execute tools at all — so the card may not
   appear. Treat it as "show the safety gate *exists*," not a guaranteed demo. (Don't target an
   operator-managed deployment like `lightspeed-console-plugin` — the agent correctly refuses those.)

**Model & version recommendation (the lesson).** **Ask mode is the guaranteed beat** — both models
answer well (gpt-oss-20b is a strong single-shot reasoner). For **Troubleshooting/agent mode**,
`granite-3.3-8b-instruct` is Red Hat's validated, tool-tuned choice — but **agent tool-execution is
sensitive to the OLS operator version**: it ran cleanly on v1.0.x and regressed on v1.1.0 (see Lessons
learned). If the agent demo matters, verify/pin the operator version. See the README
["Which model?"](../README.md#model-matrix-self-hosted).

**Point made:** **Ask** is identical to SaaS and rock-solid; cluster-aware **Troubleshooting** works
when the OLS version cooperates — and either way, **no token billing, no rate limits, and nothing
leaves the cluster**. It all ran on your single GPU, on a Red Hat–validated model you control.

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
- **Fitting a ~14–15 GiB model on one 24 GB L4 is tight — three memory levers** (all encoded in `infra/60`):
  - **Context** `--max-model-len=24576`: 32k OOMs the KV cache for a full **bf16** 8B (granite ~15 GiB
    weights → only ~4.3 GiB free; 32k needs ~5). 24k fits and still holds the agent tool catalog.
  - **GPU memory** `--gpu-memory-utilization=0.90`: 0.95 filled the L4 so completely there was no
    headroom for **CUDA-graph capture** → OOM allocating 16 MiB at startup. 0.90 leaves ~1 GiB.
  - **Concurrency** `--max-num-seqs=16`: the default 256 makes vLLM warm up the sampler with 256 dummy
    requests → OOM. A demo is single-user, so 16 is ample and keeps full context.
  - (Quantized gpt-oss MXFP4 ~13.7 GiB has more room than bf16 granite — quantization changes the math.)
- **Single-GPU rollout deadlock** — a rolling update can't place the new pod (the old one holds the
  only GPU). Use `deploymentStrategy: Recreate`.

### Provisioning flow

- **`--switch` to self-hosted didn't build the GPU stack.** `do_switch` only repointed the OLSConfig,
  so on a cluster that never ran a full self-hosted provision it aimed OLS at a model that doesn't
  exist → "Connection error" / no `inferenceservice` CRD. `do_switch` now runs `apply_infra` too.
- **DSCInitialization is immutable.** Newer RHOAI auto-creates `default-dsci` with an immutable
  `spec.monitoring.namespace`; re-applying our own with a different value fails ("MonitoringNamespace
  is immutable") and halts provisioning. `apply_infra` now creates the DSCI only if one is absent.

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
- **The OLS operator version gates agent tool execution — Ask mode is bulletproof; agent
  tool-execution depends on the OLS version lining up.** On OLS **v1.0.x** granite executed the MCP
  tools (real `pods_list` results from the cluster). After the operator **auto-upgraded to v1.1.0**,
  the *same* model + runtime (hermes parser, `--enable-auto-tool-choice`, tools attached:
  `tool_defs=5816`, 24 tools loaded) **stopped calling tools** — it answers from the docs/RAG instead
  (`tool_results=0`, `outcome=llm_stream_stop` on round 1). It's not the config or the runtime — every
  other variable was identical; only the operator version changed. **Pin the operator**
  (`installPlanApproval: Manual` + a known-good `startingCSV` in the Subscription) so an auto-upgrade
  can't silently change agent behavior mid-demo. (v1.1.0 also added `spec.ols.toolFilteringConfig` and
  `spec.ols.mcpServer` — investigate before relying on agent mode on a new OLS version.)

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

**Ask mode** — "how do I…" (docs knowledge, no cluster access):

- *"How do I expose my application to users outside the cluster?"*
- *"How do I make my app automatically scale up when it gets busy?"*
- *"I pushed a bad update — how do I roll my deployment back to the previous version?"*
- *"How do I give a teammate read-only access to just my project?"*

**Troubleshooting mode** — "what's wrong with my cluster" (live reads via MCP), easiest → hardest:

- *"Is everything in the openshift-lightspeed namespace healthy right now?"*
- *"Are any apps in my cluster crash-looping or stuck?"*
- *"My demo-scale app in openshift-lightspeed stopped working — can you tell me why?"* (after breaking it)

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
  '{"spec":{"predictor":{"model":{"args":["--served-model-name=<model>","--max-model-len=24576","--gpu-memory-utilization=0.90","--max-num-seqs=16"]}}}}'
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
maximum model length" in the error — set `--max-model-len` below it (24576 is the safe default here),
keep `--gpu-memory-utilization=0.90` + `--max-num-seqs=16` (0.95 / 256 OOM on a single L4 — see the
memory-levers note in Lessons learned), then drop `contextWindowSize` to match.

**New predictor pod stuck `Pending` after a model/config change — "Insufficient nvidia.com/gpu".**
A single-GPU rolling update deadlocks: the surge brings the new pod up before the old releases the
only GPU. The predictor uses `deploymentStrategy: Recreate` (set in `infra/60`) so the old pod is
torn down first. If a live update is already wedged, free the GPU by deleting the old (Running) pod:
`oc delete pod -n lightspeed-llm <old-predictor-pod>`.

**Want a faster, friction-free model?** A 20B reasoning model on a single L4 is slow for interactive
chat and tight on context for agent mode. `--model granite-3.3-8b-instruct` has a large context, is
~2-3× faster on an L4, and still does tool-calling — the dependable choice for live demos. Keep
gpt-oss-20b for the "self-hosted reasoning model" story when latency isn't on the clock.
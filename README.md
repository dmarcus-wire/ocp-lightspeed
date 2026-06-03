# ocp-lightspeed

Provision **Red Hat OpenShift Lightspeed** two ways on OpenShift-on-AWS, repeatably, with
Kustomize + `oc apply -k`. Built for repeat demos on fresh sandbox clusters.

- **Pattern 1 — Hosted SaaS:** Lightspeed talks to **OpenAI's** hosted API.
- **Pattern 2 — Self-hosted:** Lightspeed talks to a model **you serve on OpenShift AI (vLLM)**,
  including the full GPU stack to make that possible.

Both patterns also demonstrate Lightspeed's **Ask** and **Troubleshooting (agent)** modes, and
toggleable extras: a Route, query redaction, token quotas, and cluster interaction.

> **Why two patterns?** `OLSConfig` is **cluster-scoped and must be named `cluster`**, so only one
> can exist at a time. You stand one up, tear it down, and stand up the other — exactly the demo flow.

**The docs, in order:**

- **[docs/DEMO.md](docs/DEMO.md)** — the guided walkthrough: provision → SaaS → self-hosted (picking
  a model that executes tools on your OLS version) → business value → lessons. **Start here to run or
  present the demo.**
- **This README** — reference: prerequisites, the quick start, which model to pick, using your own
  OpenAI key, and switching. (Failure modes & fixes live in DEMO.md's *Lessons learned*.)
- **[docs/HEALTH_CHECK.md](docs/HEALTH_CHECK.md)** — verify/recover the stack after a sandbox restart.

---

## Prerequisites

- A running OpenShift-on-AWS cluster (4.16+) and **cluster-admin** (e.g. `kubeadmin`).
- For **self-hosted**: AWS quota for at least one **GPU instance** (e.g. `g6.xlarge` L4, or
  `g6e.2xlarge` L40S). The repo creates the GPU MachineSet for you.
- **Nothing cluster-specific is hardcoded.** Every environment value (apps domain, infra ID,
  region/AZ/AMI/subnet, inference endpoint) is read from your live `oc` session at run time, so the
  same repo works on every freshly provisioned cluster — the console URL and (always-changing)
  kubeadmin password are never needed by the tooling.

---

## Quick start — self-service via the Web Terminal (recommended)

No local tooling required; everything runs in the browser.

1. **Log in** to the OpenShift console as a cluster admin.
2. **Install the Web Terminal Operator**: OperatorHub → search *Web Terminal* → Install
   (or `oc apply -k bootstrap/web-terminal`).
3. **Launch the web terminal** — the `>_` icon in the console masthead. It opens already
   authenticated as you, with `oc` ready (no `oc login` needed).
4. **Clone and run:**

   ```bash
   git clone https://github.com/dmarcus-wire/ocp-lightspeed.git
   cd ocp-lightspeed
   ./provision.sh
   ```

5. Follow the prompts: pick a pattern, enter your OpenAI key (SaaS) or model tier (self-hosted),
   choose which optional features to enable. The script installs the operator, waits for the CRD,
   creates secrets, (self-hosted) builds the GPU + model-serving stack in order, and applies the
   `OLSConfig`.

   ```bash

   ==> Optional features (enable any; all are recommended for a full demo):
   enable 'route'? [y/N] n
   enable 'query-filters'? [y/N] n
   enable 'token-quota'? [y/N] n
   enable 'agent-troubleshooting'? [y/N] y
   ```

6. Verification commands

    ```bash
    oc get olsconfig cluster -o jsonpath='{.status.overallStatus}{"\n"}'   # want: Ready/healthy
    oc get pods -n openshift-lightspeed                                     # lightspeed-app-server Running
    oc get olsconfig cluster -o jsonpath='{.spec.llm.providers[0].url}{"\n"}'  # should end in /v1, your in-cluster InferenceService host
    ```

Switch patterns later with `./provision.sh --switch`. Tear down config with `./provision.sh --uninstall`.

### Keep your clone across sessions (optional)

The web terminal is ephemeral — `/home/user` is wiped when it idles out, so by default you re-`git
clone` every session. To persist the home dir (and your clone), enable `persistUserHome` on the
DevWorkspace Operator **after** the Web Terminal Operator is installed, then close and reopen the
terminal:

```bash
oc apply -f bootstrap/web-terminal/devworkspace-config.yaml   # persistUserHome + 4h idle timeout
# verify (DevWorkspace Operator 0.26+ / OCP 4.16+): a PVC should back the terminal home
oc get pvc -A | grep -i terminal
```

Don't want to touch operator config? Make re-cloning a non-event instead — one idempotent line that
clones-or-updates and drops you into the repo:

```bash
[ -d ~/ocp-lightspeed ] && git -C ~/ocp-lightspeed pull || git clone https://github.com/dmarcus-wire/ocp-lightspeed.git ~/ocp-lightspeed; cd ~/ocp-lightspeed
```

(`persistUserHome` survives the terminal idling/restarting; a fully rebuilt cluster still starts fresh.)

## What it installs & the toggleable features

Both patterns install the Lightspeed operator + provider secret, then apply the `OLSConfig`. The
self-hosted pattern also builds the GPU + vLLM serving stack in dependency order (~30–45 min, mostly
GPU driver install + model load; every step idempotent). The full step-by-step is in
[docs/DEMO.md](docs/DEMO.md).

**Modes:** *Ask* = doc-grounded Q&A (any provider). *Troubleshooting* = the model calls the in-cluster
Kubernetes **MCP** server to read live state ("why is *this* pod failing?") — needs the
`agent-troubleshooting` feature **and** a tool-calling model (see "Which model?" below).

**Toggleable features** (`components/`, opt in at provision time):

| Feature | Adds | Why |
| --- | --- | --- |
| `route` | external Route to `lightspeed-app-server` | curl the API / wire another client |
| `query-filters` | regex redaction before the LLM | scrub PII (esp. SaaS); does *not* filter MCP tool output |
| `token-quota` | per-user + cluster token caps | cost control |
| `agent-troubleshooting` | MCP introspection + tool-approval | powers Troubleshooting mode |
| RAG *(scaffolded, off)* | ground answers in your runbooks | see `components/agent-troubleshooting/patch.yaml` |

---

## Model matrix (self-hosted)

> **Which model? (read this first.)** Model choice matters more than size for this demo, and the
> right agent model depends on your **Lightspeed operator version**:
>
> - **Troubleshooting / agent mode → `qwen3-8b`.** On the current operator (**OLS 1.1.0+**) Qwen3
>   reliably drives the MCP tool-loop — it executes the cluster tools and answers from live state.
>   *Recommended default for a live showcase.* It's a reasoning model, so `provision.sh` defaults to
>   `--thinking hide` (its `<think>` scratchpad is split out of the answer); pass `--thinking show`
>   to stream the reasoning live instead.
> - **`granite-3.3-8b-instruct` — Red Hat's validated tool model, but regressed on OLS 1.1.0.** It
>   drove tools reliably on **v1.0.x**; the v1.1.0 operator stopped executing tools for it (it answers
>   from docs instead — `tool_results=0`). Still the right pick **if** you've pinned the operator to
>   v1.0.x; otherwise use Qwen3. (See DEMO.md *Lessons learned* for the full regression write-up.)
> - **Ask mode / "self-hosted reasoning model" story → `gpt-oss-20b`.** Strong single-shot answers,
>   but on this RHOAI 2.20 / vLLM stack it's **unreliable in agent mode** (it reads one tool, then
>   returns an empty answer). Great for Ask, not for Troubleshooting demos.
> - **Bigger isn't the fix.** Agent reliability is about the model's tool-calling, not parameter
>   count — and anything past ~14B (quantized) won't fit a single L4 (24 GB) anyway.

Models are Red Hat **validated models** packaged as **ModelCar OCI images** from the public catalog
`quay.io/redhat-ai-services/modelcar-catalog` (no pull secret). Pick a
tier with `MODEL=` / `INSTANCE=` (or via `provision.sh`); change `infra/60` accordingly.

| Tier | SaaS model | Self-host model (modelcar tag) | AWS GPU instance | Notes |
| --- | --- | --- | --- | --- |
| Min (8B) | `gpt-4o-mini` | `granite-3.3-8b-instruct` / `llama-3.1-8b-instruct` | `g6.xlarge` (1×L4) / `g5.2xlarge` (1×A10G) | smallest footprint; granite agent mode needs OLS v1.0.x |
| **Agent (default)** | **`gpt-4o`** | **`qwen3-8b`** (bf16 ~15 GB) | **`g6.2xlarge` (1×L4, default)** | **executes MCP tools on OLS 1.1.0** — recommended for Troubleshooting |
| Ask / reasoning | `gpt-4o` | `gpt-oss-20b` (MXFP4 ~16 GB) | `g6.2xlarge` (1×L4) | strong single-shot answers; unreliable in agent mode |
| Large | `gpt-4o` | `qwen3-14b` / `granite-4.0-h-small` / `gpt-oss-120b` | `g6e.2xlarge` (L40S); 70B/120B → multi-GPU | best tool selection; 14B won't fit a single L4 |

> **Why `g6.2xlarge`, not `g6.xlarge`, for the default?** Both are a single L4 (24 GB
> VRAM), but `g6.xlarge` is only 4 vCPU / 16 GiB — after node-reserved capacity and the
> GPU/NFD/monitoring daemonsets, the predictor's requests can't be satisfied and it stays
> `Pending` ("Insufficient cpu/memory"). `g6.2xlarge` (8 vCPU / 32 GiB) leaves headroom for
> vLLM and weight loading. A small 8B (e.g. `granite-3.3-8b-instruct`) can fit `g6.xlarge`, but
> `qwen3-8b` (bf16 ~15 GB weights) and the 20B want the `g6.2xlarge` host headroom.

---

## Using your own OpenAI key (SaaS)

The SaaS pattern talks to OpenAI's hosted API. You supply an **API key**; the repo already points at
`https://api.openai.com/v1` with model `gpt-4o` ([overlays/saas-openai/olsconfig.yaml](overlays/saas-openai/olsconfig.yaml)).

1. **Create an API key** at [platform.openai.com](https://platform.openai.com) → *Settings → API keys → Create
   new secret key*. Note: this is the **developer API**, separate from a ChatGPT Plus subscription — it's
   pay-per-token and needs its own billing/credits (Settings → Billing). Set a spend limit under Settings →
   Limits if you want a guardrail.
2. **Apply it** (singleton `OLSConfig`, so this *replaces* a self-hosted config — the GPU model keeps running, unused):

   ```bash
   ./provision.sh --switch --pattern saas --openai-key sk-... --features agent-troubleshooting --yes
   ```

   The key is stored **only** as the `openai-api-keys` Secret in `openshift-lightspeed` — `provision.sh`
   pipes it straight into the cluster (`oc create secret … --dry-run | oc apply`) and never writes it to
   disk or any tracked file, so it can't end up in git.

3. **Verify:** 

`oc get olsconfig cluster -o jsonpath='{.status.overallStatus} {.spec.ols.defaultModel}{"\n"}'`

Expected output `Ready gpt-4o`.

> **Key hygiene:** treat the `sk-…` value like a password — never paste it into chats, commits, issues, or
> screenshots. If it's ever exposed, **revoke it** at platform.openai.com and create a new one. The repo
> keeps it out of git by design; the only leak path is pasting it somewhere by hand.
>
> **Privacy:** in SaaS, your questions — and in Troubleshooting/agent mode, the **live cluster data** the MCP
> tools read — are sent to OpenAI. That's the trade-off vs. self-hosted (which keeps everything on-cluster).

Switch back to self-hosted any time: `./provision.sh --switch --pattern selfhosted --model qwen3-8b --yes`.

## Switching, uninstalling

```bash
./provision.sh --switch        # delete OLSConfig, apply the other pattern (guided)
./provision.sh --uninstall     # remove OLSConfig + Route (keeps operator + infra)
make uninstall-infra           # DESTRUCTIVE: remove model serving, RHOAI DSC, GPU stack
```

## Repository layout

```
provision.sh                 # guided entrypoint (oc + bash only) — what you run
Makefile                     # convenience targets for power users (`make help`)
bootstrap/web-terminal/      # optional: install the Web Terminal Operator
base/lightspeed-operator/    # shared Lightspeed operator install
components/                  # toggleable OLSConfig feature patches (route, query-filters, …)
overlays/                    # the two patterns: saas-openai/ and self-hosted-rhoai/
infra/                       # ordered GPU + OpenShift AI model-serving stack (10→60)
docs/                        # DEMO.md (walkthrough) · HEALTH_CHECK.md (recovery)
```

## References

- OpenShift Lightspeed install / configure / release notes — docs.redhat.com (product 1.0)
- OLSConfig CRD — github.com/openshift/lightspeed-operator (`api/v1alpha1/olsconfig_types.go`)
- OpenShift AI model serving — docs.redhat.com (Red Hat OpenShift AI Self-Managed)
- Red Hat AI validated models — docs.redhat.com/en/documentation/red_hat_ai/3 ·
  `quay.io/redhat-ai-services/modelcar-catalog`

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

Switch patterns later with `./provision.sh --switch`. Tear down config with `./provision.sh --uninstall`.

---

## Quick start — power user (`oc` + `make`)

```bash
# 1) Operator (shared by both patterns)
make operator

# 2a) SaaS
make secret-openai TOKEN=sk-...        # create the OpenAI key secret
oc apply -k overlays/saas-openai       # or: make saas (guided)

# 2b) Self-hosted (builds GPU stack + serves a model + applies overlay, with waits)
make secret-rhoai TOKEN=novalue
make selfhosted MODEL=gpt-oss-20b INSTANCE=g6.xlarge

# switch / inspect / remove
make switch-to-selfhosted
make infra-check
make uninstall
```

`make help` lists everything. Plain `oc apply -k <dir>` works for any layer once its prerequisite
CRDs exist — the Makefile/`provision.sh` just add the correct ordering and `oc wait`s.

---

## Plain-English: why would you do each of these?

- **OpenAI as SaaS** — Fastest path: no GPUs, no model hosting. A capable model in minutes,
  pay-per-token. Best for a quick demo or when sending prompts to a hosted API is acceptable.
  *Trade-off:* your queries (and, in Troubleshooting mode, live cluster data) leave the cluster.
- **Self-host on OpenShift AI** — Keep all data on-cluster (compliance, air-gap, data residency),
  get predictable cost at scale, and remove the external API dependency. *Trade-off:* you run GPUs
  and operate the model. This is the enterprise/regulated story.
- **Routes** — By default the OLS API is reachable only in-cluster (behind the console plugin). A
  Route exposes `lightspeed-app-server` externally so you can `curl` it or wire another client to it.
- **Filtering & redacting** — Scrub sensitive strings (emails, internal hostnames, ticket IDs) out
  of a user's question *before* it reaches the LLM — important in the SaaS pattern where text goes
  off-cluster. **Caveat:** this does **not** filter content returned by cluster-interaction (MCP)
  tools — that output is sent to the LLM as-is.
- **Bring your own knowledge (RAG)** — Point Lightspeed at *your* docs/runbooks so answers reflect
  your environment, not just public OpenShift docs. Scaffolded but **disabled** here (no document
  store yet) — see `components/agent-troubleshooting/patch.yaml`.
- **Configuring cluster interaction** — Lets Lightspeed read live cluster state via the built-in
  Kubernetes MCP server, so it can answer "why is *this* pod failing?" about *your* cluster instead
  of giving generic advice. This is what powers **Troubleshooting mode**. *Trade-off:* grants the
  assistant read access to cluster resources (and, with SaaS, sends that data to OpenAI).
- **Token quota limits** — Cap tokens per user and per cluster over a time window so a demo (or a
  noisy user) can't run up a bill or exhaust a self-hosted model. The cost-control story.

---

## Ask vs Troubleshooting modes

- **Ask mode** — default natural-language Q&A; works with any provider; grounded in OpenShift docs
  (RAG). Example: *"How do I expose a Service with a Route?"*
- **Troubleshooting mode** — environment-aware help. You can paste an alert/YAML/pod status, and
  with **cluster interaction** enabled the model (in **Agent mode**) calls the in-cluster Kubernetes
  MCP server to read live state and explain the fix. Enabled by the `agent-troubleshooting`
  component (`introspectionEnabled: true`). **Requires a tool-calling-capable model** — small models
  pick tools poorly, which is why the default self-hosted model is `gpt-oss-20b` rather than an 8B.

### Demo script
1. **Ask (SaaS):** open the console Lightspeed panel → ask a general OpenShift question → doc-grounded answer.
2. **Troubleshoot (SaaS):** break a pod (e.g. a bad image) → ask Lightspeed about it / use Agent
   mode → it reads your pod via the MCP tool and explains the fix. **Call out:** that sent live
   cluster data to OpenAI.
3. **Switch:** `./provision.sh --switch` (or `make switch-to-selfhosted`) → repeat step 2 → identical
   troubleshooting, but data **never leaves the cluster**. The contrast is the whole point.

---

## Model matrix (self-hosted)

Models are Red Hat **validated models** packaged as **ModelCar OCI images** from the public catalog
`quay.io/redhat-ai-services/modelcar-catalog` (no pull secret). Default is `gpt-oss-20b`. Pick a
tier with `MODEL=` / `INSTANCE=` (or via `provision.sh`); change `infra/60` accordingly.

| Tier | SaaS model | Self-host model (modelcar tag) | AWS GPU instance | Notes |
| --- | --- | --- | --- | --- |
| Min (8B) | `gpt-4o-mini` | `granite-3.3-8b-instruct` / `llama-3.1-8b-instruct` | `g6.xlarge` (1×L4) / `g5.2xlarge` (1×A10G) | smallest footprint |
| **Default** | **`gpt-4o`** | **`gpt-oss-20b`** (MXFP4 ~16 GB) | **`g6.xlarge`; `g6e.2xlarge` preferred** | strong reasoning + tool calling on one GPU |
| Large | `gpt-4o` | `qwen3-14b` / `granite-4.0-h-small` / `gpt-oss-120b` | `g6e.2xlarge`; 70B/120B → multi-GPU | best tool selection |

---

## Switching, uninstalling

```bash
./provision.sh --switch        # delete OLSConfig, apply the other pattern (guided)
./provision.sh --uninstall     # remove OLSConfig + Route (keeps operator + infra)
make uninstall-infra           # DESTRUCTIVE: remove model serving, RHOAI DSC, GPU stack
```

## Repository layout

See [docs/STRUCTURE.md](docs/STRUCTURE.md) for a file-by-file explanation.

## References

- OpenShift Lightspeed install / configure / release notes — docs.redhat.com (product 1.0)
- OLSConfig CRD — github.com/openshift/lightspeed-operator (`api/v1alpha1/olsconfig_types.go`)
- OpenShift AI model serving — docs.redhat.com (Red Hat OpenShift AI Self-Managed)
- Red Hat AI validated models — docs.redhat.com/en/documentation/red_hat_ai/3 ·
  `quay.io/redhat-ai-services/modelcar-catalog`

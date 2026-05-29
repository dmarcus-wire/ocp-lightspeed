# Repository structure

A file-by-file map of what each piece does and why it exists.

```
ocp-lightspeed/
├── README.md                  # overview, quick starts, rationale, demo script, model matrix
├── docs/STRUCTURE.md          # this file
├── provision.sh               # interactive entrypoint (oc + bash only)
├── Makefile                   # convenience targets for power users
├── .gitignore                 # keeps secrets/kubeconfig out of git
├── bootstrap/web-terminal/    # optional: install the Web Terminal Operator
├── base/lightspeed-operator/  # shared Lightspeed operator install
├── components/                # toggleable OLSConfig feature patches
├── overlays/                  # the two patterns (SaaS / self-hosted)
└── infra/                     # full GPU + OpenShift AI model-serving stack
```

## Top level

| Path | What it is |
| --- | --- |
| `provision.sh` | Guided, menu-driven entrypoint. Depends only on `oc` + bash + coreutils (runs in the Web Terminal). Reads all environment values from the current `oc` session — never hardcodes or asks for the console URL/password. Handles operator install, secrets, the ordered infra build (with waits), overlay apply, and `--switch` / `--uninstall`. Supports flags for non-interactive/CI use. |
| `Makefile` | Thin convenience layer. Simple actions (operator, secrets, infra-check) call `oc` directly; the complex ordered flows delegate to `provision.sh` so there's one source of truth. `make help` lists targets. |
| `.gitignore` | Excludes `*.env`, `*credentials*`, and kubeconfig files. Secrets are created out-of-band, never committed. |

## bootstrap/web-terminal/

Installs the **Web Terminal Operator** so demo users get an in-console, already-authenticated
terminal with `oc`/`kubectl` preloaded.

| File | Purpose |
| --- | --- |
| `subscription.yaml` | Subscribes to `web-terminal` (channel `fast`) from `redhat-operators` in `openshift-operators`. |
| `operatorgroup.yaml` | The global OperatorGroup (usually already present; included for self-contained apply). |
| `kustomization.yaml` | Bundles the two. |

## base/lightspeed-operator/

The **shared** operator install — applied first by both patterns, because the `ols.openshift.io`
CRD only exists after the operator CSV reaches `Succeeded`.

| File | Purpose |
| --- | --- |
| `namespace.yaml` | Creates `openshift-lightspeed`. |
| `operatorgroup.yaml` | OperatorGroup targeting `openshift-lightspeed` (the operator only supports **OwnNamespace** install mode). |
| `subscription.yaml` | Subscribes to `lightspeed-operator` / `redhat-operators` / channel `stable`. |
| `kustomization.yaml` | Bundles the three. |

## components/ — toggleable OLSConfig feature patches

Each is a Kustomize **Component** that strategic-merge-patches `OLSConfig/cluster`. Overlays opt in
by listing them under `components:`; comment one out to drop that feature from a demo.

| Component | What it adds to `spec.ols` | Demo value |
| --- | --- | --- |
| `route/` | An OpenShift `Route` (separate resource) to `lightspeed-app-server:8443`, `reencrypt`. No host set → cluster-agnostic. | Expose the OLS API externally. |
| `query-filters/` | `queryFilters` regexes (redact emails + an internal domain). | Scrub PII before it reaches the LLM. |
| `token-quota/` | `quotaHandlersConfig` with a per-user and a cluster-wide limiter; `enableTokenHistory`. | Cost control. |
| `agent-troubleshooting/` | `introspectionEnabled`, `mcpKubeServerConfig`, `toolsApprovalConfig`, `maxIterations`; commented scaffolds for BYOK RAG and external MCP servers. | Powers **Troubleshooting / Agent mode**. |

## overlays/ — the two patterns

Each overlay is a `kustomization.yaml` (base `OLSConfig` + the feature components) and an
`olsconfig.yaml`. They differ only in the LLM provider block.

| Overlay | Provider | Default model | Notes |
| --- | --- | --- | --- |
| `saas-openai/` | `type: openai`, `url: https://api.openai.com/v1` | `gpt-4o` | Secret `openai-api-keys` (key `apitoken`), out-of-band. |
| `self-hosted-rhoai/` | `type: rhoai_vllm` | `gpt-oss-20b` | `url` points at the vLLM InferenceService (`/v1`); set from the live cluster at apply time. Secret `rhoai-vllm-token`. |

## infra/ — full self-hosted GPU + model-serving stack

Ordered layers (the numeric prefixes are the apply order; `provision.sh` enforces it with waits).

| Layer | Contents | Why |
| --- | --- | --- |
| `10-gpu-machineset/` | A GPU `MachineSet` **template** (placeholder tokens). | Regenerated live by cloning an existing worker MachineSet, so all AWS coordinates come from your cluster. |
| `20-nfd/` | Node Feature Discovery operator + `NodeFeatureDiscovery` CR. | Labels nodes by hardware so the GPU operator can find GPUs. |
| `30-nvidia-gpu-operator/` | NVIDIA GPU operator (from `certified-operators`) + `ClusterPolicy`. | Installs the GPU driver/toolkit/device plugin so pods can request `nvidia.com/gpu`. |
| `40-rhoai-operator/` | Red Hat OpenShift AI operator (`rhods-operator`). | Provides the DataScienceCluster / KServe CRDs. |
| `50-datasciencecluster/` | `DSCInitialization` + `DataScienceCluster` (KServe `RawDeployment`, Service Mesh removed). | Enables single-model serving without Serverless/Service Mesh. |
| `60-model-serving/` | Data-science project namespace + vLLM `ServingRuntime` + `InferenceService` (`storageUri: oci://…modelcar`). | Serves a Red Hat validated model and exposes an OpenAI-compatible `/v1` endpoint Lightspeed consumes. |

## Key facts encoded in these manifests

- `OLSConfig` is **cluster-scoped, name `cluster`** → patterns are mutually exclusive.
- Operator install must precede any `OLSConfig` (CRD registration ordering).
- App server service is `lightspeed-app-server:8443` behind an OpenShift serving cert → Route uses `reencrypt`.
- OpenAI/vLLM credentials live in a Secret with key `apitoken`, created out-of-band.
- The self-hosted provider URL **must end in `/v1`** and is read from the live InferenceService.

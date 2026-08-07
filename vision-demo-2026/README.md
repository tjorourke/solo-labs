# vision-demo-2026

**Customer demo suite for Solo Enterprise for Istio (ambient), one self-contained notebook per demo.** A mash-up of `agentgw-multi-cluster-kind` (the multicluster story, per the "Solo Enterprise for Istio" deck from slide 24) and `istio-ambient-cert-identity-kind` (the L4/L7 workload-identity story), with **one** setup script, inline architecture and state diagrams, and no per-part helm plumbing in the demo itself.

- **Part 1 — Multicluster.** Bookinfo on both clusters, east-west gateways + `istioctl multicluster link`, agentgateway ingress, global services (`solo.io/service-scope=global` → `*.mesh.internal`), cross-cluster failover, takeover of the local hostname (`solo.io/service-takeover=true`), then the same ingress doing canary + rate limit.
- **Part 2 — L4 identity.** The petshop on `mesh1`: the certificate is the identity, authorise on it in ztunnel, identity-aware access logs, the shared-ServiceAccount gap, workload claims closing it — all at L4, no proxy in the path.
- **Part 3 — Waypoint (L7).** Add the agentgateway waypoint to the petshop: JWT authorisation, canary routing and identity-keyed rate limiting. Needs the petshop from Part 2 §2.1.
- **Part 4 — AgentRegistry.** On `mesh1`: a governed catalog of approved MCP tool servers, skills and runtimes; scaffold a dice agent with `arctl`, build/publish, kick off the **AWS Bedrock AgentCore** push in the background, deploy to kagent; roll the dice and watch the tool-call trace land in the **kagent UI** (Tracing span tree); add a tool; lock it down with a waypoint AccessPolicy; turn a REST API into MCP tools (OpenAPI → MCP); then invoke the same agent on AgentCore. Needs the extra platform standup below (and AWS + a git repo for the AgentCore beats).
- **Part 5 — Substrate (gVisor).** On its **own** `kind-substrate` cluster (kagent v0.5.2): a `SandboxAgent` runs as a gVisor-sandboxed actor on a pre-warmed `WorkerPool` — prove the sandbox, warm-vs-cold bind, golden-snapshot resume. Isolated from Part 4 (which stays on kagent v0.4.3).
- **Part 6 — Inference routing.** On its **own** `kind-inference` cluster: a standalone agentgateway fronts a vLLM-simulator pool; the GIE Endpoint Picker does KV-cache-aware routing to an `InferencePool`, with serving priority via `InferenceObjective`. (A mesh-integrated gateway can't route GIE pools, so it runs on its own non-mesh gateway.)
- **Part 7 — The AI gateway.** On `mesh1`: one agentgateway in front of every model, key and tool. Corporate model names routed across Azure OpenAI, AWS Bedrock and Anthropic (frontier models only, inference stays in Part 6); failover priority groups; JWT identity stamped on every metric; group-based model access; per-user token limits; virtual keys with a declarative budget; realised-USD chargeback by user/team/BU; and an MCP hub with per-tool authorization. Needs the small extra standup below.

The parts run **independently** — pick one per customer, or run all seven. This lab is a personal demo driver: no `index.html`, not on the site.

## Stack (validated live)

| Piece | Version |
|---|---|
| Solo Istio (Helm charts + images, ambient) | `1.30.3-solo` |
| Solo Enterprise for agentgateway (ingress + waypoint) | `v2026.7.0` |
| Gloo Platform (Gloo UI, mgmt on mesh1 + agents on both) | `2.13.2` |
| Gateway API | `v1.5.1` |
| kind clusters | `mesh1` + `mesh2` (unique — no clash with other labs) |

Trust domains are per-cluster (`mesh1` / `mesh2`), the documented 1.30.x multicluster flow — Part 2's principals read `mesh1/ns/petshop/sa/<sa>`.

## Run it

```bash
# licences: SOLO_ISTIO_LICENSE_KEY + AGENTGATEWAY_LICENSE_KEY
SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./demo-scripts/setup.sh   # ~15-20 min first run

./demo-scripts/consoles.sh    # Gloo UI (service graph spans both clusters)
# open a demo notebook (Bash kernel) → run its Connect cell → Parts 1-3
```

### Prefer the terminal? `source demo-scripts/env.sh <N>`

Every notebook's Connect cell has a terminal twin. `source` it with the demo number and
you get the same variables (`CTX`, `ISTIOCTL`, licences, …) and the right working
directory, so you can paste the notebook's `kubectl` / `istioctl` / `helm` / `arctl` /
`curl` lines straight into a shell — no Jupyter needed:

```bash
source demo-scripts/env.sh 1   # istio ambient multicluster (mesh1 + mesh2)
source demo-scripts/env.sh 2   # ztunnel L4 identity        (mesh1)
source demo-scripts/env.sh 3   # waypoint L7                (mesh1)
source demo-scripts/env.sh 4   # agentregistry + arctl login (mesh1)
source demo-scripts/env.sh 5   # kagent substrate / gVisor  (substrate)
source demo-scripts/env.sh 6   # inference routing / GIE    (inference)
source demo-scripts/env.sh 7   # AI gateway                 (mesh1)
```

Must be **sourced**, not executed (`./env.sh` runs in a subshell and the exports vanish).

**Part 4 only** needs an extra platform on `mesh1` (kagent-enterprise, in-cluster AgentRegistry, Keycloak, and the kagent Enterprise UI + telemetry on the shared `management` release in `solo-cost`) — heavy, so it is a separate one-time standup after `./demo-scripts/setup.sh`:

```bash
SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./demo-scripts/agentregistry/setup-mesh1.sh   # ~8 min
# open demo-4-agentics-vision.ipynb → run its Connect cell
```

**Part 7 only** needs a light standup on `mesh1` (two local model servers, the MCP everything-server, the `ai-gateway` Gateway + cost catalog, and a demo IdP keypair). It reads `ANTHROPIC_API_KEY` from the secrets file for the one live provider:

```bash
SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./demo-scripts/llm-gateway.sh   # ~1 min
# open demo-7-llm-gateway.ipynb → run its Connect cell
```

### All seven at once

`setup-all-labs.sh` stands up every cluster needed for the suite in one go:

```bash
SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./demo-scripts/setup-all-labs.sh
# skip parts you don't need: SKIP_MESH / SKIP_PART4 / SKIP_SUBSTRATE / SKIP_INFERENCE = true
```

| Cluster | Parts | Roughly | Notes |
|---|---|---|---|
| `mesh1` + `mesh2` | 1-4, 7 + Cost | ~11 GiB | istio ambient + agentgateway + Gloo UI + Keycloak + AgentRegistry/kagent **v0.4.3** + Cost ClickHouse + AI-gateway model servers |
| `substrate` | 5 | ~2-3 GiB | kagent **v0.5.2** + gVisor substrate — a separate cluster so it doesn't clash with Part 4's kagent |
| `inference` | 6 | ~1.5 GiB | standalone (non-mesh) agentgateway + vLLM sim + GIE |

Parts 5 and 6 are separate clusters because they need platform versions/config incompatible with mesh1. Between demos, `docker stop` a cluster's node containers to reclaim RAM — kind survives a stop/start.

Consoles are on the mesh1 LoadBalancer IP via `sslip.io` (no `/etc/hosts`): the Connect cell prints the AgentRegistry UI + Keycloak URLs.

Day-2:

```bash
./demo-scripts/reset.sh       # wipe ALL demo workloads (both parts) back to square 1, keep the platform
./demo-scripts/wake.sh        # after a laptop sleep (expired 24h leaf certs)
./demo-scripts/setup.sh teardown           # delete both clusters (full rebuild)
```

**Three levels of reset**, lightest to heaviest:
- **Reset cell** (near the top of each notebook) — undoes that demo's steps so it can be re-run; safe on a fresh cluster.
- **`./demo-scripts/reset.sh`** — hard reset the whole demo to square 1: removes every demo workload from both parts (bookinfo, petshop, warehouse) and reverts ztunnel to claims-off, but leaves the platform (mesh, agentgateway, Gloo UI, Keycloak) up and unlinks the clusters so demo-1 re-creates peering live. No rebuild — restart the demo from §1.1 / §2.1. Use this between demo runs, or to start Phase 2 clean.
- **`./demo-scripts/setup.sh teardown`** — delete the clusters entirely (full ~20-min rebuild).

## What setup.sh stands up

kind ×2 → MetalLB (pools `.140-.150` / `.160-.170` inside the kind net) → shared root CA + per-cluster intermediates (`cacerts`) → Gateway API CRDs → Solo Istio ambient via plain Helm (licence, per-cluster trust domain, multicluster peering values, JSON ztunnel logs — all Helm values, no patches) → Gloo UI (mgmt plane on mesh1, agent on both) → Solo Enterprise agentgateway on both clusters → Keycloak (realm `petshop`, alice/user + bob/admin) on mesh1. **Peering is deliberately not pre-created**: demo-1 §1.2 runs `istioctl multicluster expose` + `link` live, and `reset.sh` unlinks so every run creates it fresh.

Each notebook has its own **Reset** cell near the top, so any demo can be re-run without a rebuild.

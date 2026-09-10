# vision-demo-2026

**Customer demo suite for Solo Enterprise for Istio (ambient), one self-contained notebook per demo.** A mash-up of `agentgw-multi-cluster-kind` (the multicluster story, per the "Solo Enterprise for Istio" deck from slide 24) and `istio-ambient-cert-identity-kind` (the L4/L7 workload-identity story), with **one** setup script, inline architecture and state diagrams, and no per-part helm plumbing in the demo itself.

- **Part 1 — Multicluster.** Bookinfo on both clusters, east-west gateways + `istioctl multicluster link`, agentgateway ingress, global services (`solo.io/service-scope=global` → `*.mesh.internal`), cross-cluster failover, takeover of the local hostname (`solo.io/service-takeover=true`), then the same ingress doing canary + rate limit.
- **Part 2 — L4 identity.** The petshop on `mesh1`: the certificate is the identity, authorise on it in ztunnel, identity-aware access logs, the shared-ServiceAccount gap, workload claims closing it — all at L4, no proxy in the path.
- **Part 3 — Waypoint (L7).** Add the agentgateway waypoint to the petshop: JWT authorisation, canary routing and identity-keyed rate limiting. Needs the petshop from Part 2 §2.1.
- **Part 4 — AgentRegistry.** On `mesh1`: a governed catalog of approved MCP tool servers, skills and runtimes; scaffold a dice agent with `arctl`, build/publish, kick off the **AWS Bedrock AgentCore** push in the background, deploy to kagent; roll the dice and watch the tool-call trace land in the **kagent UI** (Tracing span tree); add a tool; lock it down with a waypoint AccessPolicy; turn a REST API into MCP tools (OpenAPI → MCP); then invoke the same agent on AgentCore. Needs the extra platform standup below (and AWS + a git repo for the AgentCore beats).
- **Part 5 — Substrate (gVisor).** On its **own** `kind-substrate` cluster (kagent 0.5.6): a `SandboxAgent` runs as a gVisor-sandboxed actor on a pre-warmed `WorkerPool`: catch `runsc` actually serving a turn, show that an idle actor is a snapshot with no process at all, watch one actor per session appear, bind extra actors in a few hundred milliseconds, and put the same three agents up as ordinary pod-backed `Agent`s to see what that costs. Isolated from Part 4 (which stays on kagent v0.4.3).
- **Part 6 — Inference routing.** On its **own** `kind-inference` cluster: a standalone agentgateway fronts a vLLM-simulator pool; the GIE Endpoint Picker does KV-cache-aware routing to an `InferencePool`, with serving priority via `InferenceObjective`. (A mesh-integrated gateway can't route GIE pools, so it runs on its own non-mesh gateway.)
- **Part 7 — The AI gateway.** On `mesh1`: one agentgateway in front of every model, key and tool. Corporate model names routed across Azure OpenAI, AWS Bedrock and Anthropic (frontier models only, inference stays in Part 6); failover priority groups; JWT identity stamped on every metric; group-based model access; per-user token limits; virtual keys with a declarative budget; realised-USD chargeback by user/team/BU; and an MCP hub with per-tool authorization. Needs the small extra standup below.

- **Part 8 — The tool layer (GitHub + MCP).** On `mesh1`: agentgateway fronts **GitHub's hosted MCP server** (44 tools, 17 of them write) and holds the PAT, so the agent carries no GitHub credential; AgentRegistry publishes it as an approved tool server whose URL is the gateway; `arctl` scaffolds a `prtriage` agent against it, deployed on kagent. Then the same release-report question is run through all four `entMcp.toolMode` settings with the round trips, schema tokens and payload measured each time, and it finishes by taking the write tools away with an `EnterpriseAgentgatewayPolicy`. Needs the Part 4 standup plus `GITHUB_PAT` (read access is enough).

### Where agent projects live

Every scaffolded agent project lands in **`agents/`** rather than at the lab root:
`agents/agentdemo/` and `agents/dice-game/` from Part 4, and `agents/prtriage/` from
Part 8, which holds both implementations of the same agent side by side:

```
agents/prtriage/
  adk-python/     the arctl-scaffolded ADK Python agent  (generated, gitignored)
  java-agent/     the same agent in Java on the same ADK
  skill/          the one approved skill both of them use
  scripts/        setup, seed, scaffold, rebuild, reload
  yaml/           the gateway backend, the policy, the catalogue entry, the deploys
  fixtures/       the frozen pull requests the demo reads
```

`PROJECT_ROOT` in `demo-scripts/agentregistry/scripts/lib.sh` is what points `arctl`
there, so nothing scatters across the lab root.

The parts run **independently** — pick one per customer, or run all seven. This lab is a personal demo driver: no `index.html`, not on the site.

## Stack (validated live)

| Piece | Version |
|---|---|
| Solo Istio (Helm charts + images, ambient) | `1.30.4-solo` |
| Solo Enterprise for agentgateway (ingress + waypoint) | `v2026.8.2` |
| Solo Enterprise for AgentRegistry | `2026.8.0` |
| Solo Enterprise for kagent (Part 4) | `0.4.3` — held, see below |
| Solo Enterprise for kagent (Part 5) | `0.5.6` |
| Solo Enterprise management (UI + telemetry) | `0.5.6` |
| Gloo Platform (Gloo UI, mgmt on mesh1 + agents on both) | `2.13.3` |
| Gateway API | `v1.5.1` |
| kind clusters | `mesh1` + `mesh2` (unique — no clash with other labs) |

**Why Part 4's kagent is held at 0.4.3 while everything else is current.** On 0.5.6 with
OIDC a `type: BYO` agent (the image `arctl` builds) deploys, runs and serves its agent
card, but never returns from an A2A turn: its callback to the controller is refused with
`user_id is required` on `/api/tasks/<id>`. Declarative agents and SandboxAgents are
unaffected, which is why Part 5 runs 0.5.6 on its own cluster and the coding harness works
there. Moving the agent to the ADK build that pairs with 0.5.6 does not help either:
`arctl` still scaffolds `kagent-adk:0.8.0-beta6`, `0.10.0` is distroless so the scaffold's
`uv sync` cannot run, and `0.10.0-full` then crash-loops because the controller injects an
entrypoint the newer image has moved. Retry with `KAGENT_ENT_VERSION=0.5.6`; every version
is overridable from the environment.

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
source demo-scripts/env.sh 8   # github + MCP tool layer    (mesh1)
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
| `substrate` | 5 | ~2-3 GiB | kagent **0.5.6** + gVisor substrate, and where the coding harness runs |
| `inference` | 6 | ~1.5 GiB | standalone (non-mesh) agentgateway + vLLM sim + GIE |

Parts 5 and 6 are separate clusters because they need platform versions/config incompatible with mesh1. Between demos, `docker stop` a cluster's node containers to reclaim RAM — kind survives a stop/start.

Consoles are on the mesh1 LoadBalancer IP via `sslip.io` (no `/etc/hosts`): the Connect cell prints the AgentRegistry UI + Keycloak URLs.

### The coding harness: agentdemo-cc

`agentdemo-cc.sh` puts the same dice agent up twice, through two different doors, on the
Part 5 cluster:

```bash
./demo-scripts/agentdemo-cc.sh up     # agentdemo (ADK image) + agentdemo-cc (harness)
./demo-scripts/agentdemo-cc.sh ask    # prompt both, print both answers
./demo-scripts/agentdemo-cc.sh down
```

- **`agentdemo`** is `type: BYO`: the image you built with `arctl`, running as a pod.
- **`agentdemo-cc`** is an `AgentHarness` with `backend: openclaw`, the claude-code
  family. It runs as a **gVisor actor on the WorkerPool**, not as a pod of its own,
  because `AgentHarness` has a required `spec.substrate` — which is why it lives here
  and not on mesh1.

It answers for itself: *"I'm Claude Haiku 4.5 running as an OpenClaw agent inside a
gVisor sandbox."* The kagent UI lists `agentdemo` as an Agent and `agentdemo-cc` as an
AgentHarness, and both can be prompted there.

Two things that will bite anyone repeating this. The controller ships without an
acp-sandbox image unless it was built with one, so the harness must name a
**digest-pinned** `substrate.workloadImage` or it reports `image digest is not set at
link time`. And a harness does not answer on A2A: it speaks the **Agent Client
Protocol** over a websocket (`initialize` → `session/new` → `session/prompt`), which is
what `acp-chat.py` does.

Day-2:

### Watch the actors (Part 5)

`substrate-scope.sh` runs [Substrate Scope](https://github.com/themsquared/substrate-scope), a live
visualiser for Agent Substrate, against the `substrate` cluster: worker bays, the restore queue,
snapshot storage and per-agent activity. It is third party (Apache-2.0) and not vendored here, so
the script clones it at a pinned commit into a gitignored directory and runs it locally.

```bash
./demo-scripts/substrate-load.sh        # everything: viewer up, agents up, chats running
./demo-scripts/substrate-load.sh stop   # stop the chats, remove the agents, stop the viewer
```

That is the whole interface for the demo. It starts the viewer itself if it is not
already up, so nothing has to happen in order and re-running it mid-flight is harmless.
`AGENTS=10 CHATS=60` in front of it tunes the load if you ever care.

Both scripts resolve everything from their own location, so they run from the suite root,
from `demo-scripts/`, or by absolute path — and neither changes your kubectl context: the
viewer gets its own pinned kubeconfig, so you can stay on `kind-mesh1` for demo 4 in the
same terminal.

`load` is what fills the board: it deploys N `SandboxAgent`s and drives real chats at them, so
bays light up, actors resume from their snapshots and checkpoint back as each turn finishes. Those
are **billable model calls**, which is why the visualiser ships a master switch that defaults to off
and why `load` takes a budget and stops there. Nothing in demo-5 itself leaves a populated board:
§5.3 deploys three extra actors but deletes them again, so use `load` for a board that stays busy.

It reads through the kagent controller API, which gives full fidelity (actors and sessions, not just
pools and pods) on this suite's cluster. Two things to know: it watches the **current** kubectl
context, so the script switches you to `kind-substrate`; and its scaling buttons really do scale the
WorkerPool, so treat them as live actions during a demo.

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

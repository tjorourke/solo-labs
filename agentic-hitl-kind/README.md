<a id="agentic-hitl--two-layer-human-in-the-loop-on-kind"></a>
# Agentic HITL: Two-layer Human-in-the-Loop on kind

Single-cluster lab showing **two distinct HITL surfaces** on one MCP-driven agent:

| Layer | Approver | Surface | Mechanism |
|---|---|---|---|
| **Agent HITL** | End user, mid-conversation | kagent chat UI | `requireApproval` on the agent's MCP tool stanza |
| **Gateway HITL** | Platform reviewer, out-of-band | `hitl-extauth` admin API (`GET /pending`, `POST /decide/{id}`) | `AgentgatewayPolicy` with `extAuth` (PreRouting): Check() parks until a decision arrives |

The same `ops-tools` MCP server backs both. The gateway distinguishes the two tiers by **path** (`/mcp/public` vs `/mcp/privileged`), so we don't need body-inspection CEL.

## Topology

```
                   ┌────────────────────────────────────────────┐
                   │  kagent agent (declarative OR LangGraph)   │
                   │  - requireApproval: [truncate_table]       │
                   └───┬─────────────────────────┬──────────────┘
                       │                         │
                       │ MCP                     │ MCP
                       ▼                         ▼
            ┌──────────────────┐      ┌─────────────────────┐
            │ RemoteMCPServer  │      │ RemoteMCPServer     │
            │  ops-tools-pub   │      │  ops-tools-privileged│
            └────────┬─────────┘      └─────────┬───────────┘
                     │                          │
                     │           agentgateway   │
                     │  ┌──────────────────────┼─────────────┐
                     │  │ /mcp/public          │ /mcp/priv   │
                     │  │  (no policy)         │  extAuth ──►│ hitl-extauth :9001
                     │  └──────────────────────┴──────┬──────┘     (parks Check)
                     ▼                                ▼                │
            ┌────────────────────────────────────────────────┐         │
            │ ops-tools MCP server (Python)                  │         │
            │  /public:   cluster_db_query, truncate_table   │         │
            │  /privileged: run_migration                    │         │
            └────────────────────────────────────────────────┘         │
                                                                       │
                                  admin HTTP :8081
                                  GET /pending
                                  POST /decide/{id} ───────────────────┘
```

## Components

| Path | Purpose |
|---|---|
| `kind/cluster.yaml`            | Single-cluster kind config |
| `scripts/01-cluster.sh`        | kind + metallb |
| `scripts/02-agentgateway.sh`   | Enterprise agentgateway install (needs licence) |
| `scripts/03-kagent.sh`         | kagent OSS install (needs OpenAI key) |
| `scripts/04-mcp-and-hitl.sh`   | Build + kind-load 2 images; apply manifests |
| `scripts/05-agents.sh`         | Apply both agents (declarative + LangGraph) |
| `scripts/quick.sh`             | Orchestrator: `up`, `teardown`, `status` |
| `scripts/port-forward.sh`      | kagent UI + hitl-extauth admin API |
| `src/ops-tools/`               | Python MCP server, mock in-memory orders DB |
| `src/hitl-extauth/`            | Go: ext-auth gRPC + admin HTTP |
| `src/langgraph-agent/`         | Python: BYO LangGraph agent + kagentCheckpointer |
| `yaml/`                        | All manifests, grouped by component |
| `demo-scripts/runbook.md`      | Live demo narrative |

## Environment

| Var | Purpose |
|---|---|
| `ANTHROPIC_API_KEY`        | **Required.** Used by both kagent (`providers.default=anthropic`, default model `claude-haiku-4-5`) and the BYO LangGraph agent. |
| `AGW_VERSION`              | Defaults to `v1.2.1`. Override to test other builds. |
| `KAGENT_VERSION`           | Defaults to latest. |
| `SECRETS_FILE`             | Optional sourceable file that exports the above. |

100% OSS: no licences, no gcloud auth. Both kagent and agentgateway pull from public
container registries (`ghcr.io/kagent-dev/...` and `cr.agentgateway.dev/...`).

## Quickstart

```bash
# 1. One key (Anthropic only — agentgateway is OSS, no license needed)
export ANTHROPIC_API_KEY=sk-ant-...

# 2. Bring it all up (~5 min first time)
./scripts/quick.sh up

# 3. Open the kagent dashboard and the reviewer API
./scripts/port-forward.sh
# kagent dashboard           → http://localhost:8080
# hitl-extauth admin API     → http://localhost:8081/pending
```

## Demo flow

See [`demo-scripts/runbook.md`](demo-scripts/runbook.md) for the live walkthrough. Short version:

1. **`cluster_db_query`** → no HITL, runs immediately.
2. **`truncate_table orders`** → agent HITL fires in the chat UI. Approve → runs.
3. **`run_migration v3`** → gateway HITL parks the call. Approve it with `POST /decide/{id}` on the admin API → runs.

## Teardown

```bash
./scripts/quick.sh teardown
```

## See also

- `CLAUDE.md`: design decisions, gotchas, integration gaps
- [Human-in-the-Loop Subagents](https://kagent.dev/docs/kagent/examples/human-in-the-loop): kagent docs

## Enterprise STS identity

The existing walkthrough is OSS HITL without delegation. `yaml-oss/` keeps
that configuration. The separate Enterprise chapter on `index.html` uses
`yaml-enterprise/`, Keycloak Bob (`bob` / `bob`, lab fixtures only) and a
`dba-agent` ServiceAccount. The agent calls Solo STS before MCP; the queue
shows `user`, `agent`, `toolName` and full `toolArgs`. Raw HTTP headers and
body are not retained in the queue. The ext-auth service extracts display
claims only after gateway JWT validation; it is not a token verifier.

```bash
./scripts/up-enterprise.sh       # new hitl-sts-part1 or hitl-sts-part2 cluster
./scripts/test-enterprise.py     # exchange, handshake, park, approve, reject
```

The page shows the actual YAML and kubectl/curl commands, not just these
shortcuts. The scripts never tear down a cluster. Licence:
`AGENTGATEWAY_LICENSE_KEY` in `~/.solo/secrets.env`; it is never printed.
Only the gateway entry point is JWT-protected. The admin API is a lab-only
ClusterIP with no reviewer authentication. Protect it separately and restrict
backend access before using this pattern outside an isolated lab. The sample
ServiceAccount has no review RBAC grants; this is not a self-approval policy.

The Enterprise chapter exercises the gateway with an explicit STS-then-MCP
client, not the kagent chat. The installed RemoteMCPServer schema supports
static `headersFrom`; that does not establish per-user JWT propagation from
the pinned chat runtime. The local `agentsts-adk` SDK reads a subject token
from session headers, but this lab has not verified that attachment path.
The original kagent and LangGraph walkthrough remains unchanged on OSS.

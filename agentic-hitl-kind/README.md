# Agentic HITL — Two-layer Human-in-the-Loop on kind

Single-cluster lab showing **two distinct HITL surfaces** on one MCP-driven agent:

| Layer | Approver | Surface | Mechanism |
|---|---|---|---|
| **Agent HITL** | End user, mid-conversation | kagent chat UI | `requireApproval` on the agent's MCP tool stanza |
| **Gateway HITL** | Platform reviewer, out-of-band | Standalone approval queue UI | `AgentgatewayPolicy` with `extAuth` (PreRouting) — Check() parks until a decision arrives |

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
                                  hitl-ui :8080 ◄───── HTMX poll ──────┘
                                  (browser tab)        & decide POST
```

## Components

| Path | Purpose |
|---|---|
| `kind/cluster.yaml`            | Single-cluster kind config |
| `scripts/01-cluster.sh`        | kind + metallb |
| `scripts/02-agentgateway.sh`   | Enterprise agentgateway install (needs license) |
| `scripts/03-kagent.sh`         | kagent OSS install (needs OpenAI key) |
| `scripts/04-mcp-and-hitl.sh`   | Build + kind-load 3 images; apply manifests |
| `scripts/05-agents.sh`         | Apply both agents (declarative + LangGraph) |
| `scripts/quick.sh`             | Orchestrator: `up`, `teardown`, `status` |
| `scripts/port-forward.sh`      | kagent UI + hitl-ui + gateway access |
| `src/ops-tools/`               | Python MCP server, mock in-memory orders DB |
| `src/hitl-extauth/`            | Go: ext-auth gRPC + admin HTTP |
| `src/hitl-ui/`                 | Go: HTMX approval queue UI |
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

100% OSS — no licenses, no gcloud auth. Both kagent and agentgateway pull from public
container registries (`ghcr.io/kagent-dev/...` and `cr.agentgateway.dev/...`).

## Quickstart

```bash
# 1. One key (Anthropic only — agentgateway is OSS, no license needed)
export ANTHROPIC_API_KEY=sk-ant-...

# 2. Bring it all up (~5 min first time)
./scripts/quick.sh up

# 3. Open the two UIs (each in its own browser tab)
./scripts/port-forward.sh
# kagent dashboard → http://localhost:8080
# hitl approval UI → http://localhost:8090
```

## Demo flow

See [`demo-scripts/runbook.md`](demo-scripts/runbook.md) for the live walkthrough. Short version:

1. **`cluster_db_query`** → no HITL, runs immediately.
2. **`truncate_table orders`** → agent HITL fires in the chat UI. Approve → runs.
3. **`run_migration v3`** → gateway HITL fires in the approval queue UI (separate tab). Different role approves → runs.

## Teardown

```bash
./scripts/quick.sh teardown
```

## See also

- `CLAUDE.md` — design decisions, gotchas, integration gaps
- [Human-in-the-Loop Subagents](https://kagent.dev/docs/kagent/examples/human-in-the-loop) — kagent docs

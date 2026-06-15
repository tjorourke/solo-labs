# agent-frameworks-kind

One Kubernetes SRE incident, one three-role crew, built five ways on the same
enterprise stack — and all five run on Solo Enterprise for kagent and route every
LLM call and tool call through enterprise agentgateway.

The crews: a kagent-native declarative agent-team, and BYO crews in Google ADK,
LangGraph, CrewAI and AutoGen. The incident: a `checkout` Deployment pinned to a
non-existent image (`ImagePullBackOff`). Each crew diagnoses it, plans the fix, and
applies it so `checkout` recovers.

## Topology

```
  Alice (Keycloak, group field-fte)
        | A2A message/send  (kagent mints an OBO token: sub=alice, act.sub=<agent>)
        v
  kagent controller ──► one of the crews (declarative team, or BYO ADK/LangGraph/CrewAI/AutoGen)
                              |                         |
                     LLM /v1/chat/completions     tools /mcp
                              |                         |
                              v                         v
                    enterprise agentgateway  ──────────────────┐
                       |  ai.provider: anthropic (translates OpenAI<->Anthropic)
                       |  prompt guard on the LLM route
                       v                         v
                     Claude                k8s-ops MCP server ──► patches incident/checkout
```

## Prerequisites

- docker, kind, kubectl, helm, gcloud (authenticated for the Solo public chart
  registry), openssl, python3, curl.
- Secrets (export, or point `SECRETS_FILE` at a sourceable file):
  - `ANTHROPIC_API_KEY` — the model behind the gateway
  - `SOLO_LICENSE_KEY` — Solo Enterprise for kagent
  - `AGENTGATEWAY_LICENSE_KEY` — enterprise agentgateway

## Quickstart

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export SOLO_LICENSE_KEY=...
export AGENTGATEWAY_LICENSE_KEY=...
./scripts/quick.sh up            # ~12-15 min on a cold cluster (enterprise pulls)

# Prove the gateway data path (no agent involved):
./scripts/check-gateway.sh       # OpenAI-compatible -> Claude, and /mcp tool list

# Resolve the incident as Alice with any crew:
AGENT=sre-crew-crewai    ./scripts/ask.sh "the checkout service is down - investigate, then fix it"
AGENT=sre-crew-adk       ./scripts/ask.sh "..."
AGENT=sre-crew-autogen   ./scripts/ask.sh "..."
AGENT=sre-crew-langgraph ./scripts/ask.sh "..."   # pauses at its approval step (HITL)
AGENT=sre-crew-kagent    ./scripts/ask.sh "..."   # asks for approval in the dashboard

# Add the gateway prompt guard (applies to all five crews at once):
./scripts/07-augment.sh

# kagent dashboard:
./scripts/port-forward.sh        # http://localhost:8080
```

Reset the incident between runs: `kubectl --context kind-frameworks apply -f yaml/incident/checkout.yaml`

Teardown: `./scripts/quick.sh teardown`

## Layout

```
scripts/   01-cluster 02-keycloak 03-agentgateway 04-kagent  (enterprise bring-up)
           05-scenario (incident + k8s-ops MCP + gateway data path)
           06-crews    (build BYO images, apply all crews)
           07-augment  (prompt guard)
           quick.sh / check-gateway.sh / ask.sh / mint-token.sh / port-forward.sh
src/       k8s-ops (MCP server) + sre-crew-{adk,langgraph,crewai,autogen} (BYO images)
yaml/      incident/ mcp/ agentgateway/ agents/ keycloak/ namespaces/
```

See `CLAUDE.md` for the design rationale, the dependency-pinning gotchas, and the
live verification status.

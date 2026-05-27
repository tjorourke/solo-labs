# Runbook — agentic-hitl-kind live demo

A ~10-minute walkthrough of two-layer human-in-the-loop on an MCP-driven agent.

## Cast of characters

| Role | What they own |
|---|---|
| **End user** | The person chatting with the agent in kagent dashboard. Approves contextual things they asked for. |
| **Platform reviewer** | Watches the gateway approval queue in a second browser tab. Approves things that affect shared infrastructure. |

Same human plays both roles in this demo, but use two browser tabs to make the role boundary obvious.

## Setup

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/quick.sh up
./scripts/port-forward.sh   # leave this running
```

Then open both tabs:

- `http://localhost:8080` — **kagent dashboard** (end user)
- `http://localhost:8090` — **HITL approval queue** (platform reviewer)

Select the `dba-assistant` agent (or `dba-assistant-langgraph` for the BYO variant) in the kagent UI.

## Scene 1 — read-only, no HITL

In the kagent chat, type:

> What's in the orders table?

The agent calls `cluster_db_query("SELECT * FROM orders")`. No approval prompts anywhere. The agent comes back with the row list. **Point out:** no friction for safe reads.

## Scene 2 — agent HITL fires in the chat

In the kagent chat:

> Truncate the orders table.

The agent picks `truncate_table`. The chat **pauses** with an approval card:

```
┌─────────────────────────────────────────────┐
│  Tool call requires approval                │
│  truncate_table(table: "orders")            │
│  [ Approve ]   [ Reject ]                   │
└─────────────────────────────────────────────┘
```

The HITL approval queue tab (the platform reviewer's tab) shows nothing — this is the user's call, not the platform's.

Approve. Tool runs, orders is empty, agent confirms.

**Point out:** the gate lives inside the agent's tool stanza (`requireApproval`). The agent itself paused — kagent's chat UI rendered the actionable card.

## Scene 3 — gateway HITL fires in the platform queue

Switch back to the kagent chat:

> Apply migration v3.

The agent picks `run_migration("v3")` and the chat shows "tool call dispatched — waiting on downstream approval".

In the **HITL approval queue tab** a new card appears:

```
run_migration                                14:32:11
                                 path /privileged/mcp
{
  "version": "v3"
}
[ Approve ]  [ Reject ]
```

The card includes the parsed JSON-RPC tool name and arguments — extracted at the gateway via `forwardBody` purely for display. The gating decision is path-based.

Click **Approve**. The kagent chat unfreezes; the agent reports the migration succeeded.

**Point out:** different role, different UI, same MCP wire protocol. The agent doesn't even know there's a gate — agentgateway parked the HTTP request before it reached the MCP server.

## Scene 4 — rejection path

Repeat Scene 3. This time, click **Reject** in the approval queue.

The agent receives an `HTTP 403` with the denial reason `{"approved": false, "reason": "rejected by reviewer"}` and reports the failure verbatim. It does not retry.

**Point out:** denial reasons round-trip cleanly. Auditors can see who rejected what and why.

## Inspecting state

While running:

```bash
# Mock DB state + audit log
kubectl --context kind-hitl -n ops-tools port-forward svc/ops-tools 8081:8080 &
curl -s localhost:8081/state | jq

# Pending requests directly from ext-auth
kubectl --context kind-hitl -n hitl exec deploy/hitl-extauth -- \
  wget -qO- http://localhost:8081/pending | jq

# ext-auth logs
kubectl --context kind-hitl -n hitl logs deploy/hitl-extauth --tail=20
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Gateway IP stays `<pending>` for >2 min | MetalLB pool exhausted | `kubectl -n metallb-system get ipaddresspool kind-pool -o yaml` and adjust |
| RemoteMCPServer never marks tools as discovered | gateway svc name differs from `hitl-gateway` | `kc -n agentgateway-system get svc` then update `yaml/mcp/remote-mcp-servers.yaml` |
| LangGraph agent pod CrashLoopBackoff with "could not load MCP tools" | gateway not ready when agent starts | Pod will retry up to 20× × 3s; if it persists, check ops-tools is `Ready` and `kubectl -n hitl logs deploy/hitl-extauth` for `Check parked` lines on any test request |
| Gateway HITL approval card never appears in `hitl-ui` | extAuth not firing — check `AgentgatewayPolicy` status is `Accepted: True, Attached: True` | `kc -n ops-tools get agentgatewaypolicy privileged-extauth -o yaml \| grep -A5 conditions` |

## Teardown

```bash
./scripts/quick.sh teardown
```

## Talking points

- **Two role boundaries, one MCP server.** The gate is at the gateway for cross-team trust; at the agent for end-user consent.
- **Path-based gating beats body inspection** for the simple case — visible in the topology, no CEL.
- **A parking ext-auth is a real pattern.** Envoy's `Check()` may take however long it takes; the agent's tool call simply hangs as "pending" until a decision arrives.
- **Same wire from the agent's perspective.** Whether the gate is in the agent (requireApproval) or at the gateway (extAuth), the tool call is a single MCP `tools/call` that either succeeds, fails with a reason, or — for the gateway case — pauses for a while first.

# agentic-budgets-kind

Per-team LLM token budgets, enforced at the agentgateway.

A single kind cluster. Two kagent BYO LangGraph chat agents — one for the
**dba** team, one for the **support** team — each baked with a team-scoped
JWT. Both agents talk to a mock LLM (Python, ~150 LOC) through Solo
Enterprise agentgateway. The gateway:

1. Validates the JWT (RS256, JWKS fetched from an in-cluster issuer).
2. Reads the response body's `usage.total_tokens` for every
   `/v1/chat/completions` reply.
3. Debits the matched team's hourly + daily token bucket.
4. Returns **HTTP 429** on the next request once the bucket is exhausted.

Budgets:

| Team    | Per-hour    | Per-day      |
| ------- | ----------- | ------------ |
| dba     | **5,000**   | **50,000**   |
| support | **20,000**  | **200,000**  |

The DBA agent burns through its hourly budget after 4–5 long-essay prompts.
The next prompt returns "Sorry — your team's LLM token budget is exhausted."
The support agent — same code, different JWT — is unaffected and keeps
answering.

Grafana + Prometheus (via kube-prometheus-stack) visualise the spend live.

## Layout

```
agentic-budgets-kind/
├── kind/cluster.yaml          # 2-node kind cluster
├── scripts/                   # 01..07 + quick.sh orchestrator
├── src/
│   ├── mock-llm/              # Starlette /v1/chat/completions
│   ├── jwt-issuer/            # Go RSA keypair + 2 team JWTs
│   └── langgraph-agent/       # BYO chat agent (httpx, no MCP)
└── yaml/                      # gateway, route, ratelimit, dashboard, agents
```

## Bring it up

Needs only one secret (the agents talk to the mock LLM, not OpenAI):

```bash
export AGENTGATEWAY_LICENSE_KEY=...
./scripts/quick.sh up
./scripts/port-forward.sh   # leave running
```

Then open:
- http://localhost:8080  — kagent dashboard
- http://localhost:3000  — Grafana (admin / admin) → "Per-Team LLM Token Budgets"

## Demo

1. **Baseline.** Both agents idle, dashboard shows 0/5000 for dba, 0/20000 for support.
2. **Burn through DBA.** Ask `dba-agent` to "write a long essay about indexes" 4–5 times. Watch dba's hourly counter climb. Around 5,000 the next prompt comes back **429** — surfaced to the user verbatim.
3. **Switch to support.** Same prompt. Still works — different team, separate counter.
4. **Reset.** Wait the hour (or `kubectl delete pod -n agentgateway-system -l app.kubernetes.io/component=ratelimit` to clear the in-memory counters), and DBA can chat again.

## Teardown

```bash
./scripts/quick.sh teardown
```

## See also

- Sibling lab — [agentic-mcp-rbac-kind](../agentic-mcp-rbac-kind/) — per-user MCP tool RBAC at the gateway. Same JWT pattern, different gateway policy.
- Sibling lab — [agentic-hitl-kind](../agentic-hitl-kind/) — two-layer human-in-the-loop on an MCP agent.

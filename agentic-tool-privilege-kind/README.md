# agentic-tool-privilege-kind

**Part 2** of the agentic contract series (Part 1: `agentic-structured-output-kind`).
Part 1 proved the *shape* two agents share. This one is about *who is allowed to
act on it*: give each agent an identity, and scope what MCP tools that identity may
call, so **one agent can do something the other can't**.

Two agents diagnose the same locked database. Only one may fix it.

- **dba-diagnoser** — identity `db-reader`. Can inspect the database and report a
  Diagnosis. The privileged tool is invisible to it.
- **sre-remediator** — identity `db-operator`. Same MCP server, but it may also call
  `db_reset_credentials` and actually unlock the database.

The boundary is enforced at the **enterprise agentgateway**, not in the agents.
The gateway validates each agent's JWT and applies a per-tool authorization policy
keyed on the token's `groups` claim, so it filters `tools/list` and refuses
`tools/call` per identity.

## Mock Postgres — no real database

The "orders" database is a small **MCP server that simulates Postgres** — it starts
locked (superuser password never set) and `db_reset_credentials` unlocks it. Nothing
real to deploy; the incident is deterministic and re-arms on a pod restart.

## Why this is enterprise-only

- `EnterpriseAgentgatewayPolicy` `backend.mcp.authorization` (per-tool CEL over the
  JWT claims + tool name) and `jwtAuthentication` — no OSS equivalent.
- Runs on Solo Enterprise for kagent + enterprise agentgateway + Keycloak.

No Istio/ambient mesh is needed: the MCP authorization happens at the agentgateway
in front of the tool server.

## Bring it up

Separate kind cluster (`tool-privilege`), enterprise licenses required:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export SOLO_LICENSE_KEY=...             # Solo Enterprise for kagent
export AGENTGATEWAY_LICENSE_KEY=...     # enterprise agentgateway
./scripts/quick.sh up
```

The Solo charts are pulled from Google Artifact Registry, so `gcloud` must be
installed and authenticated (`helm registry login` is run for you).

## See it

```bash
./scripts/tools.sh     # tools/list as db-reader vs db-operator — different tool sets
./scripts/prove.sh     # reader refused db_reset_credentials; operator runs it, DB recovers
./scripts/ask.sh dba-diagnoser  "the orders database is down - diagnose it"
./scripts/ask.sh sre-remediator "the orders database is down - fix it"
```

`tools.sh` is the headline: the same MCP endpoint returns three tools to the reader
and four to the operator. `prove.sh` fires the privileged tool with each identity —
refused for one, applied for the other, and the simulated database goes from
`degraded` to `healthy`.

## Identity

Each agent injects its own Keycloak token on every MCP call, via its
`RemoteMCPServer.headersFrom`. The realm has two agent identities:
`agent-diagnoser` (group `db-reader`) and `agent-remediator` (group `db-operator`).
Tokens are minted at standup and stored as Secrets; the realm sets a 12h lifespan,
so if they expire run `./scripts/refresh-tokens.sh`.

## Reset / teardown

```bash
kubectl --context kind-tool-privilege -n mock-db rollout restart deploy/mock-db  # re-arm the locked DB
./scripts/quick.sh teardown                                                       # delete the cluster
```

## Notes

- Needs `docker`, `kind`, `kubectl`, `helm`, `curl`, `python3`, `gcloud`.
- Standalone `tool-privilege` kind cluster — independent of Part 1's cluster.
- See `CLAUDE.md` for design notes and the end-to-end verification record.
- Related: Part 1 (`agentic-structured-output-kind`) — the shared contract;
  `agentic-a2a-kind` — the user→agent OBO identity hop;
  `agentic-mcp-rbac-kind` — per-user MCP tool RBAC at the gateway.

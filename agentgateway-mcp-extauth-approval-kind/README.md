# Human approval for high-risk MCP tools through agentgateway, by ConfigMap

Hold high-risk MCP tool calls at agentgateway until a platform reviewer approves
or rejects them. The MCP server does not implement approval. Two policies split
the work:

- **Native MCP authorization** (`yaml/agentgateway/mcp-authz.yaml`) on the
  `users-mcp` MCP backend allows `get_users` and `delete_user`. Every other
  tool, such as `wipe_users`, is left out of `tools/list` and refused on call
  by agentgateway with JSON-RPC `-32602`. Allow and deny live here.
- **The `hitl-tool-policy` ConfigMap** only names tools that must wait for a
  human. `hitl-extauth` selects the server's block and parks any tool that
  matches its approve list.

```yaml
users-mcp:
  approve:
    - delete_.*
```

```yaml
# mcp-authz.yaml, spec.backend.mcp.authorization
action: Allow
policy:
  matchExpressions:
    - 'mcp.tool.target == "users-mcp" && mcp.tool.name in ["get_users", "delete_user"]'
```

`get_users` on `users-mcp` runs immediately. `delete_user` waits for a reviewer.
`wipe_users` passes ext-auth and is refused by agentgateway. Each approve entry
is a Go regular expression matched against the whole tool name. Rules under one
server never apply to another. Frames with no tool name, including
`initialize` and `tools/list`, always pass. If the ConfigMap file has never
loaded, every tool call is denied rather than run without review.

A tool in the approve list must also be on the native allow-list. ext-auth is
a route policy and runs before the MCP backend, so a parked tool that native
authorization refuses would reach a reviewer and then be refused anyway.

## Identifying the MCP server

The HTTPRoute sends `/mcp` to the `users-mcp` AgentgatewayBackend
(`yaml/agentgateway/mcp-backend.yaml`), which has one MCP target, also named
`users-mcp`. With one target, tool names stay unprefixed (`prefixMode`
defaults to `Conditional`). `serverForPath` reads the HTTP path from the
ext-auth `CheckRequest`, which is the client's `/mcp`, and explicitly binds it
to `users-mcp`. The OSS and Enterprise HTTPRoutes use an exact `/mcp` match and
only that backend. Other paths resolve to no server, so nothing parks there.
Caller-supplied headers, JSON server fields and tool prefixes cannot select a
server block. Query parameters do not change the binding.

This is a lab route binding, not automatic MCP server discovery. A new server
needs its own route and a corresponding binding in `serverForPath`, as well as
its own ConfigMap block. Do not send a federated, multi-server endpoint through
this binding. Only `users-mcp` is deployed here. `server_test.go` checks that the
three route manifests, the MCP backends, the native tool policies and this
binding agree.

Executed on 7 November 2026 at 21:56 GMT on the existing `mcp-extauth-approval`
cluster (agentgateway 1.5.0): approve-only `GET /policy`, handshake
passthrough, `tools/list` returning `get_users` and `delete_user`,
`get_users` without approval, `wipe_users` refused with `-32602` and never
parked, `delete_user` parked and approved, a second delete rejected. With the
native policy removed for a moment, `tools/list` also returned `wipe_users`.
`evidence/server-policy-replay.txt` contains the captured output. The cluster
is left running.

The Enterprise path was replayed at 22:06 GMT on `hitl-sts-part2`
(enterprise-agentgateway v2026.10.0) with `scripts/test-enterprise.py` and
`scripts/test-bob-via-agent.py`; see `evidence/verification-*.txt`.
Cross-server isolation is executed in Go unit tests only. No second MCP server
is deployed here.

To repeat the OSS test without teardown, restore the mock users, forward the
admin port in another terminal, then run the test:

```bash
kubectl --context kind-mcp-extauth-approval -n mcp-extauth-demo rollout restart deploy/users-mcp
kubectl --context kind-mcp-extauth-approval -n mcp-extauth-demo rollout status deploy/users-mcp
kubectl --context kind-mcp-extauth-approval -n mcp-extauth-demo port-forward svc/hitl-extauth-admin 18081:8081
# In another terminal, from this lab directory:
python3 scripts/test-server-policy.py
```

## Reviewer API

`GET /pending` lists parked calls with `serverName`, tool name and arguments.
`POST /decide/{id}` approves or rejects one. `GET /policy` returns the loaded
approve rules under `servers`, plus file path, load time and any reload error. Invalid
YAML or regular expressions leave the last good policy in place. ConfigMap file
updates normally take about a minute to reach the pod on kind.

`GET /metrics` exposes `hitl_extauth_approval_needed_total{server,tool}`,
`hitl_extauth_verdicts_total{verdict,server,tool}`, `hitl_extauth_pending` and
`hitl_extauth_decisions_total{result=approved|rejected|timeout}`. Handshake
frames are not counted. Alert on calls needing approval or a non-empty queue.
The admin API is lab-only and needs separate reviewer authentication and network
restrictions outside an isolated lab.

## Run it

```bash
./scripts/up.sh      # kind cluster + agentgateway v1.5.0 (OSS) + users-mcp + hitl-extauth
# follow the lab page for the test flow
./scripts/down.sh
```

`scripts/quick.sh` runs the whole flow non-interactively (bring-up, `/policy`,
passthrough, park/approve with `/metrics`, park/reject, `wipe_users` refused
by native MCP authorization, teardown) and prints PASS. Its EXIT trap deletes the kind cluster, so do not
point it at a cluster someone is still reviewing.

The full walkthrough with captured payloads is the lab page (`index.html`,
published on the site). See also `agentgateway-mcp-write-approval-kind`, the
backend-driven alternative for when you own the MCP server's own code instead
of fronting an opaque one.

## Enterprise STS identity: Bob direct, then Bob through an agent

The existing walkthrough is OSS HITL without delegation. `yaml-oss/` keeps
that configuration and has no STS. The separate Enterprise chapter on
`index.html` uses `yaml-enterprise/`, Keycloak Bob (`bob` / `bob`, lab
fixtures only) and shows the same `delete_user` call two ways:

1. Bob calls MCP himself with his Keycloak token. The gateway accepts the
   Keycloak issuer as well as Solo STS (`sts-jwt.yaml`), and the queue shows
   `user: bob` with no `agent` (`evidence/pending-bob-direct.json`).
2. Bob asks the kagent `dba-agent` to remove a user. kagent OSS 0.10.6 passes
   Bob's bearer token to the BYO agent (`src/dba-agent`), which runs as the
   `dba-agent` ServiceAccount, exchanges Bob's token at Solo STS with its own
   ServiceAccount token as the actor, then calls MCP. The queue shows
   `user: bob` and `agent: dba-agent` (`evidence/pending-bob-via-agent.json`).

Raw HTTP headers and body are not retained in the queue. The ext-auth service
extracts display claims only after gateway JWT validation; it is not a token
verifier.

```bash
./scripts/up-enterprise.sh       # new hitl-sts-part1 or hitl-sts-part2 cluster
./scripts/test-enterprise.py     # exchange, Bob direct, handshake, park, approve, reject
./scripts/up-agent.sh            # Part 2 only: kagent 0.10.6 + the BYO dba-agent
kubectl --context kind-hitl-sts-part2 -n mcp-extauth-demo rollout restart deploy/users-mcp
./scripts/test-bob-via-agent.py  # Bob prompts the agent; queue shows bob + dba-agent
```

Restart `users-mcp` before `test-bob-via-agent.py`: `test-enterprise.py`
deletes `u-2`, and the agent test asks for the same user to be removed.

The page shows the actual YAML and kubectl/curl commands, not just these
shortcuts. None of these scripts tear down a cluster (`scripts/quick.sh` does,
so do not use it here). Secrets: `AGENTGATEWAY_LICENSE_KEY` and
`ANTHROPIC_API_KEY` in `~/.solo/secrets.env`; they are passed on stdin and
never printed. Only the gateway entry point is JWT-protected. The admin API is
a lab-only ClusterIP with no reviewer authentication. Protect it separately
and restrict backend access before using this pattern outside an isolated lab.
The sample ServiceAccount has no review RBAC grants; this is not a
self-approval policy.

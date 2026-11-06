# agentgateway-mcp-extauth-approval-kind: gate one MCP write tool at the gateway, let every get_* tool straight through

A kind lab for agentgateway's `extAuth` traffic policy gating a real MCP server
(the `mcp.server.fastmcp` Python SDK, not a hand-rolled JSON-RPC shim) by tool
name: `get_users` always passes straight through; `delete_user` parks at an
Envoy ext-authz `Check()` call until a human approves or rejects it from a
separate admin API. One endpoint, one `AgentgatewayPolicy`, one gRPC service —
`users-mcp` itself has no idea any of this exists.

Adapted from the proven `hitl-extauth` Go service in `agentic-hitl-kind`
(which gates by HTTPRoute path instead); this variant gates by reading the
tool name out of the JSON-RPC body, so one route can mix always-allowed and
always-gated tools.

Highlights:

- `get_users` returns in well under a second; `delete_user` genuinely blocks
  the connection open — proven by backgrounding the call and watching it sit
  with no output until `/decide/{id}` resolves it.
- Approve → the gateway forwards the call, `users-mcp` deletes the user.
  Reject → the gateway returns the denial itself; `users-mcp` never sees the
  call (confirmed: the rejected user is still there afterwards).
- The approval queue is a small HTTP API (`GET /pending`, `POST /decide/{id}`)
  you can drive with curl — no bundled UI, swap in Slack/Backstage/ServiceNow
  as you like.

## Run it

```bash
./scripts/up.sh      # kind cluster + agentgateway v1.5.0 (OSS) + users-mcp + hitl-extauth
# follow the lab page for the test flow
./scripts/down.sh
```

`scripts/quick.sh` runs the whole flow non-interactively (bring-up, passthrough,
park/approve, park/reject, teardown) and prints PASS.

The full walkthrough with captured payloads is the lab page (`index.html`,
published on the site). See also `agentgateway-mcp-write-approval-kind` — the
backend-driven alternative for when you own the MCP server's own code instead
of fronting an opaque one.

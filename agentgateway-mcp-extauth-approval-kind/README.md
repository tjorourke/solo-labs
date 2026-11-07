# agentgateway-mcp-extauth-approval-kind: gate MCP tool calls at the gateway from a ConfigMap

A kind lab for agentgateway's `extAuth` traffic policy gating a real MCP server
(the `mcp.server.fastmcp` Python SDK, not a hand-rolled JSON-RPC shim) by tool name, using allow / approve / deny lists in the `hitl-tool-policy`
ConfigMap: `get_users` matches `get_.*` and passes straight through,
`delete_user` matches `delete_.*` and parks at an Envoy ext-authz `Check()`
call until a platform reviewer approves or rejects it from a separate admin
API, and any tool name that matches nothing is denied. One endpoint, one
`AgentgatewayPolicy`, one gRPC service. `users-mcp` itself has no idea any of
this exists.

Adapted from the proven `hitl-extauth` Go service in `agentic-hitl-kind`
(which gates by HTTPRoute path instead); this variant gates by reading the
tool name out of the JSON-RPC body and matching it against allow, approve and
deny lists in a ConfigMap, so one route can mix allowed, gated and denied tools.

Highlights:

- `get_users` returns in under a second. `delete_user` blocks the connection
  open, proven by backgrounding the call and watching it sit with no output
  until `/decide/{id}` resolves it.
- Approve: the gateway forwards the call and `users-mcp` deletes the user.
  Reject: the gateway returns the denial itself and `users-mcp` never sees the
  call (the rejected user is still there afterwards).
- `wipe_users` matches no list and is denied in under a second without being
  parked, even though `users-mcp` has no such tool.
- The caller (whoever started the MCP session) waits. A platform reviewer
  decides from the admin API.
- The approval queue is a small HTTP API (`GET /pending`, `POST /decide/{id}`,
  `GET /policy`) you can drive with curl. No bundled UI; swap in Slack, Backstage or ServiceNow
  as you like.
- `GET /metrics` on the admin port serves `hitl_extauth_approval_needed_total{tool}`,
  `hitl_extauth_pending`, `hitl_extauth_verdicts_total{verdict,tool}` and
  `hitl_extauth_decisions_total{result=approved|rejected|timeout}`. Handshake
  frames (`initialize`, `tools/list`) are not counted.
- The allow, approve and deny lists live in the `hitl-tool-policy` ConfigMap.
  Each entry is a Go regular expression matched against the whole tool name,
  so `get_users` is exact, `get_.*` matches a prefix, and `.*` matches every
  tool from this server. Precedence is deny, then approve, then allow, then
  default deny. Edit the ConfigMap and `hitl-extauth` reloads the file when
  its contents change (about a minute for the kubelet to sync on kind).

## Run it

```bash
./scripts/up.sh      # kind cluster + agentgateway v1.5.0 (OSS) + users-mcp + hitl-extauth
# follow the lab page for the test flow
./scripts/down.sh
```

`scripts/quick.sh` runs the whole flow non-interactively (bring-up, `/policy`,
passthrough, park/approve with `/metrics`, park/reject, default deny,
teardown) and prints PASS. Its EXIT trap deletes the kind cluster, so do not
point it at a cluster someone is still reviewing.

The full walkthrough with captured payloads is the lab page (`index.html`,
published on the site). See also `agentgateway-mcp-write-approval-kind`, the
backend-driven alternative for when you own the MCP server's own code instead
of fronting an opaque one.

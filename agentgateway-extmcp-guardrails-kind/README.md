# ExtMCP guardrails: gate agentgateway's MCP tool calls with your own gRPC server

Credit: Michael Levan (AI Architect, Solo.io) wrote the first look at this feature,
[MCP Guardrails: Gate Tool Calls at the Method Layer With Agentgateway](https://www.cloudnativedeepdive.com/mcp-guardrails-gate-tool-calls-at-the-method-layer-with-agentgateway/).
This lab is the hands-on follow-up.

A kind lab for agentgateway's ExtMCP guardrails (OSS, shipped in v1.3.0, 18 June
2026): an external gRPC server that agentgateway calls before forwarding an MCP
`tools/call` and after an MCP server answers `tools/list`, built from the actual
`ext_mcp.proto` contract rather than the docs' demo `testbox` image.

`src/server.py` is a deliberately small MCP server with one destructive tool
(`delete_contact`) that trusts whoever calls it. `src/policy_server.py` is the
guardrail: it denies `delete_contact` unless the call carries `X-Role: admin`,
and mutates `tools/list` to flag the gated tool at discovery time. Both
outcomes, plus a plain Pass, are driven through the gateway and captured on the
wire.

Highlights:

- A real `AuthorizationError.PERMISSION_DENIED` becomes JSON-RPC `-32001` at
  the client, with the policy server's own reason text.
- `tools/list` mutation: the gated tool's description is rewritten before the
  client ever tries it.
- `failureMode: FailClosed` vs `FailOpen`, proven live by killing the policy
  server: FailClosed blocks even the harmless tool the policy would have
  passed; FailOpen lets the gated, destructive tool through unauthenticated.

## Run it

```bash
./scripts/up.sh      # kind cluster + agentgateway v1.5.0 (OSS) + crm-mcp + guardrail-mcp
# follow the lab page for the test flow
./scripts/down.sh
```

`scripts/quick.sh` runs the whole flow non-interactively (bring-up, Pass/Deny/
admin-Pass, FailClosed outage, teardown) and prints PASS.

The full walkthrough with captured payloads is the lab page (`index.html`,
published on the site).

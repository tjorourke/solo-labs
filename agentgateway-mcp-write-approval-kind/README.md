# agentgateway-mcp-write-approval-kind: pause a destructive MCP tool call for human confirmation, no kagent required

A kind lab for MCP's own confirmation mechanism (MRTR: an `input_required`
result carrying an HMAC-protected `requestState`), relayed unmodified by
agentgateway (OSS, v1.5.0). `get_users` runs straight through; `delete_user`
pauses on the first call, asks for an explicit accept/decline, and only
deletes once the client resubmits the call with the operator's answer and the
signed state. The gate is entirely backend-side: agentgateway's job is just
to carry the pause/resume messages through to the client unmodified.

This is the practical answer to "how do we get explicit per-call
confirmation on a write-capable MCP tool when kagent isn't in the agent
loop" -- no Enterprise, no agent framework, just the MCP 2026-07-28 spec's
own elicitation/MRTR surface plus a backend that uses it.

Built from `agentgateway-mcp-2026-kind` (the full MRTR + Tasks reference
lab), trimmed to just the confirmation gate on one destructive tool.

## Run it

```bash
./scripts/up.sh      # kind cluster + users-mcp + agentgateway v1.5.0 (OSS)
# follow the lab page for the curl flow
./scripts/down.sh
```

`scripts/quick.sh` runs the whole flow non-interactively (get_users,
no-capability refusal, MRTR pause/resume accept, tamper check, MRTR
pause/resume decline, teardown) and prints PASS.

## The flow, with curl

```bash
GW=http://localhost:30080/mcp
META='{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"demo-client","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}}'

# 1. get_users: no gate
curl -s "$GW" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: get_users' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_users\",\"arguments\":{},\"_meta\":$META}}"

# 2. delete_user: first call pauses with input_required + requestState
curl -s "$GW" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: delete_user' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-2\"},\"_meta\":$META}}"

# 3. resubmit with the operator's answer + the requestState from step 2
curl -s "$GW" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: delete_user' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_user\",\"arguments\":{\"id\":\"u-2\"},\"inputResponses\":{\"confirm_delete\":{\"action\":\"accept\",\"content\":{\"confirm\":true}}},\"requestState\":\"<paste from step 2>\",\"_meta\":$META}}"
```

A client whose `_meta` omits the `elicitation` capability gets refused
outright on `delete_user`, fail-closed: the backend will not delete without
a confirmation channel. A tampered `requestState` fails HMAC verification
and is rejected with `-32602`.

The full walkthrough with captured payloads is the lab page (`index.html`,
published on the site).

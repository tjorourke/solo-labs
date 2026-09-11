#!/bin/bash
# Composable MCP: one tool name, several HTTP steps, one answer.
#
# Enterprise only. Without it, an agent that needs two calls makes two calls, and
# the joining logic lives in the agent or in an MCP server somebody has to write
# and run. Here the steps are configuration.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

TOK="$(mint_token all)"
SID="$(mcp_init "$TOK")"

hdr "1. The composed tool is just another tool to the client"
log "node-report is defined under mcp.targets[].custom in config.yaml. The client"
log "cannot tell it apart from a tool an MCP server published:"
mcp_rpc "$TOK" "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq -r '.result.tools[] | select(.name | test("node.report")) | "    \(.name)\n    \(.description)"'

hdr "2. Its input schema is declared, so a model can fill it in"
mcp_rpc "$TOK" "$SID" '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' \
  | jq -r '.result.tools[] | select(.name | test("node.report")) | .inputSchema' | sed 's/^/    /'

hdr "3. One call, two HTTP requests inside the gateway"
# prefixMode: always namespaces every tool with its target, so the composed tool
# is node-report_node-report. Read the name from tools/list rather than assuming
# it, because the prefix is a config choice.
TOOL="$(mcp_rpc "$TOK" "$SID" '{"jsonrpc":"2.0","id":9,"method":"tools/list"}' \
  | jq -r '.result.tools[] | select(.name | test("node.report")) | .name' | head -1)"
[[ -n "$TOOL" ]] || die "the composed tool is not in tools/list"
log "tool name: $TOOL"
NOTE="lab-$(date +%s)"
log "calling with note=$NOTE"
OUT="$(mcp_rpc "$TOK" "$SID" \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":{\"note\":\"$NOTE\"}}}" \
  | jq -r '.result.content[0].text // (.error|tostring)')"
echo "$OUT" | sed 's/^/    /'
echo
expect_contains "the answer carries the note from step two" "$NOTE" "$OUT"
expect_contains "and the node id from step one" "i-" "$OUT"

cat <<'EOT'

  Read the answer again: it names the node from the first step and the header the
  second step sent, joined by a CEL expression in the config file. The agent made
  one call and paid for one round trip.

  The steps ran on whichever node the load balancer picked, so the composed tool
  is as available as the fleet is. Nothing was deployed to make it exist.
EOT

hdr "4. Which node composed it"
log "Ten calls, so you can see the fleet answering:"
for _ in $(seq 1 10); do
  mcp_rpc "$TOK" "$(mcp_init "$TOK")" \
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":{\"note\":\"$NOTE\"}}}" \
    | jq -r '.result.content[0].text // empty' | awk '{print $2}'
done | sort | uniq -c | sed 's/^/    /'

summary

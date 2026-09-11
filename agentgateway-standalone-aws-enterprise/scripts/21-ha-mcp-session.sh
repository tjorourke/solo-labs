#!/bin/bash
# The best property of this deployment: MCP sessions are portable between nodes.
#
# agentgateway serialises MCP session state (which targets are in the session,
# their upstream session ids, and the backend address), encrypts it with
# AES-256-GCM using config.session.key, and hands the ciphertext to the client as
# the Mcp-Session-Id. Every node loads the same key from Secrets Manager, so any
# node can decrypt a session any other node issued.
#
# That is why the target group has stickiness switched off.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

TOK="$(mint_token all)"

hdr "1. Open a session through the load balancer"
HDRS="$(mktemp)"
curl -s -D "$HDRS" -X POST "$GATEWAY_URL/mcp" \
  -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"1"}}}' >/dev/null
SID="$(grep -i '^mcp-session-id' "$HDRS" | sed 's/.*: //' | tr -d '\r\n')"
rm -f "$HDRS"
[[ -n "$SID" ]] || die "no session id was issued"

log "session id (${#SID} characters):"
echo "    ${SID:0:100}..."
log ""
log "A lookup key would be a UUID, 36 characters. This is longer because it is not"
log "a key: it is the encrypted session state itself. Nothing about this session is"
log "stored on the node that created it."

hdr "2. Drive the same session at every node in turn, directly"
cat <<'EOT'
  Bypassing the load balancer entirely and talking to each node's private address,
  so there is no question of the ALB routing back to the origin node.
EOT
echo

declare -a NODES IPS
while read -r id; do
  ip="$(aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  NODES+=("$id"); IPS+=("$ip")
done < <(fleet_instances)


# Calling a specific node means originating the request inside the VPC, so it runs on
# one node over SSM. Rather than escaping a JSON body through several layers of shell,
# the body is base64-encoded and decoded on the node.
mcp_call_node() { # mcp_call_node <client-node> <target-ip> <token> <session> <tool> -> "HTTP <code>|<body>"
  local client="$1" ip="$2" tok="$3" sid="$4" tool="$5"
  local body b64
  body="$(jq -nc --arg t "$tool" '{jsonrpc:"2.0",id:42,method:"tools/call",params:{name:$t,arguments:{}}}')"
  b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
  node_try "$client" "printf %s '$b64' | base64 -d > /tmp/mcp.json && curl -s -w '|HTTP %{http_code}' -X POST http://$ip:3000/mcp -H 'authorization: Bearer $tok' -H 'mcp-session-id: $sid' -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' --data-binary @/tmp/mcp.json"
}

CLIENT="${NODES[0]}"
log "running the client from $CLIENT over SSM"
echo

for i in "${!NODES[@]}"; do
  out="$(mcp_call_node "$CLIENT" "${IPS[$i]}" "$TOK" "$SID" echo_whoami)"
  httpc="$(printf '%s' "$out" | sed -n 's/.*|HTTP //p' | tr -d ' ')"
  served="$(printf '%s' "$out" | sed -n 's/^data: //p' | head -1 | jq -r '.result.content[0].text // "{}"' 2>/dev/null | jq -r '.node // "?"' 2>/dev/null)"
  if [[ "$httpc" == "200" ]]; then
    printf '  %s  ok%s   %-20s HTTP 200, tool ran on %s\n' "$c_green" "$c_off" "${NODES[$i]}" "${served:-?}"
    PASS=$((PASS+1))
  else
    printf '  %sFAIL%s   %-20s HTTP %s\n' "$c_red" "$c_off" "${NODES[$i]}" "${httpc:-?}"
    FAIL=$((FAIL+1))
  fi
done
printf '%s' "$c_off"

log ""
log "One session, three different processes on three different instances, all of"
log "which could decrypt it. No shared session store, no sticky sessions, and no"
log "coordination between the nodes."

hdr "3. The same thing through the load balancer, at volume"
log "Stickiness is off, so these round-robin. Every one carries the same session."
# A plain string rather than an associative array: macOS ships bash 3.2, which has
# neither declare -A nor mapfile.
seen=""
okc=0; badc=0
for i in $(seq 1 12); do
  r="$(curl -s -X POST "$GATEWAY_URL/mcp" \
      -H "authorization: Bearer $TOK" -H "mcp-session-id: $SID" \
      -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":$((100+i)),\"method\":\"tools/call\",\"params\":{\"name\":\"echo_whoami\",\"arguments\":{}}}" \
      | sed -n 's/^data: //p' | head -1)"
  node="$(echo "$r" | jq -r '.result.content[0].text // "{}"' 2>/dev/null | jq -r '.node // "?"' 2>/dev/null)"
  if echo "$r" | grep -q '"result"'; then okc=$((okc+1)); seen="$seen$node\n"; else badc=$((badc+1)); fi
done
log "12 tool calls on one session: $okc succeeded, $badc failed"
log "nodes that served them: $(printf '%b' "$seen" | sort -u | grep . | tr '\n' ' ')"
expect "every call on the shared session succeeded" 12 "$okc"

hdr "4. Now break it, so the mechanism is not taken on faith"
cat <<'EOT'
  If the portability came from something other than the shared key, changing the
  key on one node would not matter. Give one node a different session key and the
  same session id becomes undecryptable ciphertext to it.

  This edits the node's env file directly and restarts it. Nothing in S3 or in
  Aurora changes, so the node is put back by re-rendering from Secrets Manager.
EOT
echo
ODD="${NODES[1]}"
log "giving $ODD a different session key"
node_exec "$ODD" "sed -i \"s/^SESSION_KEY=.*/SESSION_KEY='$(openssl rand -hex 32)'/\" /etc/agentgateway/env && systemctl restart agentgateway" >/dev/null
sleep 15

out="$(mcp_call_node "$CLIENT" "${IPS[1]}" "$TOK" "$SID" echo_whoami | sed -n 's/.*|HTTP //p' | tr -d ' ')"
log "the same session sent to the odd node: HTTP $out"
if [[ "$out" == "200" ]]; then
  warn "expected the odd node to refuse the session; it accepted it"
  FAIL=$((FAIL+1))
else
  ok "the odd node cannot decrypt a session it did not issue (HTTP $out)"
  PASS=$((PASS+1))
fi

log "and the other two still accept it:"
for i in 0 2; do
  out="$(mcp_call_node "$CLIENT" "${IPS[$i]}" "$TOK" "$SID" echo_whoami | sed -n 's/.*|HTTP //p' | tr -d ' ')"
  printf '    %-20s HTTP %s\n' "${NODES[$i]}" "$out"
  expect "${NODES[$i]} still accepts the session" 200 "$out"
done

log ""
log "restoring $ODD from Secrets Manager"
SECRET_ARN="$(tf_out runtime_secret_arn)"
node_exec "$ODD" "KEY=\$(aws secretsmanager get-secret-value --secret-id $SECRET_ARN --query SecretString --output text --region $AWS_REGION | jq -r .SESSION_KEY) && sed -i \"s|^SESSION_KEY=.*|SESSION_KEY='\$KEY'|\" /etc/agentgateway/env && systemctl restart agentgateway" >/dev/null
sleep 15
out="$(mcp_call_node "$CLIENT" "${IPS[1]}" "$TOK" "$SID" echo_whoami | sed -n 's/.*|HTTP //p' | tr -d ' ')"
expect "the restored node accepts the session again" 200 "$out"

hdr "5. The limit of this, which the config comments also state"
cat <<'EOT'
  Both MCP targets in this lab are remote, and that is not incidental.

  The encrypted session state includes the upstream's address. A stdio target is a
  child process of one specific node, so even though another node can decrypt the
  session id perfectly, the process that session refers to does not exist there.
  Remote targets over streamable HTTP are what make the session genuinely portable.

  If you take one thing from this lab into a real deployment: on a multi-node
  standalone fleet, do not use stdio MCP targets.
EOT

summary

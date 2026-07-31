#!/bin/bash
# The hybrid config store: a change made on one node, live on all three.
#
# In the default `file` storage mode, editing anything in the admin UI writes back
# to the local config file. On a fleet that means three files immediately
# disagreeing with each other and with S3, and the next config sync silently
# reverts whichever one you edited.
#
# In `hybrid` mode the file from S3 is the baseline and UI edits go to Aurora
# instead, with PostgreSQL LISTEN/NOTIFY telling the other nodes the overlay
# changed. This script drives the same admin API the UI uses.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

MODEL="overlay-demo-$RANDOM"

NODES=(); IPS=()
while read -r id; do
  ip="$(aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  NODES+=("$id"); IPS+=("$ip")
done < <(fleet_instances)
AUTHOR="${NODES[0]}"

# The admin API is bound to loopback on each node, so it is never exposed. Calls
# run on the node itself over SSM Session Manager.
models_on() { # models_on <node-index>  -> space-separated model ids
  node_exec "${NODES[$1]}" "curl -s http://127.0.0.1:15000/api/config/effective >/dev/null; curl -s -H 'x-api-key: agw_sk_platform_demo' http://127.0.0.1:3000/v1/models | jq -r '[.data[].id] | join(\" \")'" 2>/dev/null | tr -d '\n' | sed 's/  */ /g'
}
overlay_on() { # overlay_on <node-index> -> kind/id lines
  node_exec "${NODES[$1]}" "curl -s http://127.0.0.1:15000/api/config/resources | jq -r '.resources[]? | \"\(.kind)/\(.id)\"'" 2>/dev/null
}

hdr "1. Storage mode on each node"
for i in "${!NODES[@]}"; do
  m="$(node_try "${NODES[$i]}" "curl -s http://127.0.0.1:15000/config_dump | jq -r '.config.storage.mode // \"?\"'" 2>/dev/null | tr -d '\n ')"
  printf '  %-20s %-14s storage.mode=%s\n' "${NODES[$i]}" "${IPS[$i]}" "$m"
done
log ""
log "Aurora writer: $(tf_out aurora_writer_endpoint)"
log "Each node reads the file baseline from S3 and the overlay from that cluster."
log ""
log "Overlay-backed resource kinds: modelCatalog, llm.provider, llm.model,"
log "llm.virtualModel, llm.apiKey, llm.policy, mcp.target, mcp.policy, mcp.settings,"
log "traffic.gateway, traffic.route, traffic.tcpRoute, ui.policy."

hdr "2. Before"
log "Models published by each node, from the file baseline only:"
for i in "${!NODES[@]}"; do printf '  %-20s %s\n' "${NODES[$i]}" "$(models_on "$i")"; done
log ""
log "Overlay contents:"
overlay_on 0 | sed 's/^/    /' || true
[[ -z "$(overlay_on 0)" ]] && log "    (empty)"

hdr "3. Add a model on one node only"
log "PUT /api/config/resources/llm.model on $AUTHOR"
log "This is exactly what the Models page in the admin UI does."
BODY="$(jq -nc --arg n "$MODEL" \
  '{resources:[{value:{name:$n, provider:{reference:"openai"}, params:{model:"gpt-4o-mini"}}}]}')"
resp="$(node_exec "$AUTHOR" "curl -s -X PUT http://127.0.0.1:15000/api/config/resources/llm.model -H 'content-type: application/json' -d '$BODY'" 2>/dev/null)"
echo "$resp" | jq -c '.resources[]? | {kind,id,revision}' 2>/dev/null | sed 's/^/    /' || echo "    $resp"
expect_contains "the resource was stored" "$MODEL" "$resp"
log ""
log "Nothing was written to S3 and nothing was written to a local file. The row went"
log "to Aurora, and the write issued a pg_notify the other nodes were listening for."

hdr "4. After: every node publishes it"
sleep 5
found=0
for i in "${!NODES[@]}"; do
  m="$(models_on "$i")"
  if [[ "$m" == *"$MODEL"* ]]; then
    printf '  %s  ok%s %-20s %s\n' "$c_green" "$c_off" "${NODES[$i]}" "$m"; found=$((found+1))
  else
    printf '  %sFAIL%s %-20s %s\n' "$c_red" "$c_off" "${NODES[$i]}" "$m"
  fi
done
expect "all three nodes publish a model created on one of them" 3 "$found"
log ""
log "No restart, no config push, no sync timer involved. The other two nodes were"
log "told, and reloaded their own state."

hdr "5. And it serves traffic through the load balancer"
c="$(code -H 'x-api-key: agw_sk_platform_demo' "$GATEWAY_URL/v1/models")"
expect "models endpoint" 200 "$c"
r="$(curl -s "$GATEWAY_URL/v1/chat/completions" -H 'x-api-key: agw_sk_platform_demo' \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg m "$MODEL" '{model:$m, max_tokens:20, messages:[{role:"user",content:"Reply with one word: ok"}]}')")"
echo "$r" | jq -c '{model: (.model // "?"), content: (.choices[0].message.content // .error.message)}' | sed 's/^/    /'
expect_contains "the overlay model answers a real request" "ok" "$(echo "$r" | jq -r '.choices[0].message.content // ""' | tr 'A-Z' 'a-z')"

hdr "6. It survives destroying the node that created it"
cat <<'EOT'
  This is what separates a database overlay from a local file. The node that made
  the change is about to be terminated. Its replacement never saw the request, and
  the config file in S3 has never heard of this model.
EOT
echo
log "terminating $AUTHOR"
aws ec2 terminate-instances --instance-ids "$AUTHOR" >/dev/null
T0="$(date +%s)"
for i in $(seq 1 90); do
  h="$(healthy_count)"; cur="$(fleet_instances)"
  printf '    t+%-4ss healthy=%s\n' $(( $(date +%s) - T0 )) "$h"
  if [[ "$h" == "3" ]] && ! echo "$cur" | grep -q "^$AUTHOR$"; then break; fi
  sleep 10
done
echo
fleet_table

# Rebuild the node list; one of these has never seen the API call.
NODES=(); IPS=()
while read -r id; do
  ip="$(aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  NODES+=("$id"); IPS+=("$ip")
done < <(fleet_instances)

log ""
log "Models on the fleet now, including the replacement:"
found=0
for i in "${!NODES[@]}"; do
  m="$(models_on "$i")"
  mark="   "; [[ "${NODES[$i]}" != "$AUTHOR" ]] && mark="   "
  if [[ "$m" == *"$MODEL"* ]]; then
    printf '  %s  ok%s %-20s %s\n' "$c_green" "$c_off" "${NODES[$i]}" "$m"; found=$((found+1))
  else
    printf '  %sFAIL%s %-20s %s\n' "$c_red" "$c_off" "${NODES[$i]}" "$m"
  fi
done
expect "the replacement node inherited the overlay from Aurora" 3 "$found"
expect "still serving through the load balancer" 200 "$(code -H 'x-api-key: agw_sk_platform_demo' "$GATEWAY_URL/v1/models")"

hdr "7. Remove it"
LIVE="${NODES[0]}"
node_exec "$LIVE" "curl -s -X DELETE http://127.0.0.1:15000/api/config/resources/llm.model/$MODEL" 2>/dev/null | sed 's/^/    /'
sleep 5
gone=0
for i in "${!NODES[@]}"; do
  m="$(models_on "$i")"
  [[ "$m" != *"$MODEL"* ]] && gone=$((gone+1))
done
expect "removed from all three nodes" 3 "$gone"

hdr "Why this matters"
cat <<EOT
  An admin UI on a single box is a convenience. On a fleet it is either a liability
  or a control plane, and storage.mode decides which.

  file    three nodes each write their own copy, and the next sync from S3
          silently reverts whichever one you edited.

  hybrid  the file stays the reviewed baseline in git and in S3, and the things an
          operator legitimately changes at runtime - virtual keys, model entries,
          MCP targets - live in Aurora where every node can see them, including
          nodes that do not exist yet.

  Two things to know before relying on it:
    hybrid requires config.database.url, and refuses to start on PostgreSQL with
    maxConnections below 2, because the overlay holds a LISTEN connection open
    alongside its query pool.

    In hybrid mode the config file is round-tripped through JSON and back out
    through the YAML emitter before shell expansion runs. A quoted variable
    reference survives that unquoted, so a value that only becomes numeric after
    expansion loses the quoting it needed. That is why guardrailVersion is a
    literal in config.yaml and not a variable.

  Try it in the browser: $GATEWAY_URL/ui
EOT

summary

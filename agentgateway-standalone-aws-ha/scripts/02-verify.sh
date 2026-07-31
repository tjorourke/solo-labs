#!/bin/bash
# Confirm the fleet is healthy and the same config is live on every node.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools; require_aws; require_stack

hdr "Fleet"
fleet_table
echo
target_health

hdr "Three nodes in service"
expect "healthy targets" 3 "$(healthy_count)"

hdr "Every node is running the same build and the same config"
for id in $(fleet_instances); do
  ver="$(node_exec "$id" '/usr/local/bin/agentgateway --version | tr -d "\n "' 2>/dev/null | tr -d '\n ')"
  sum="$(node_exec "$id" 'sha256sum /etc/agentgateway/config.yaml | cut -c1-12' 2>/dev/null | tr -d '\n ')"
  printf '  %-20s version=%s config=%s\n' "$id" "${ver:-?}" "${sum:-?}"
  sums+=("$sum")
done
uniq_sums="$(printf '%s\n' "${sums[@]}" | sort -u | wc -l | tr -d ' ')"
expect "all nodes hold an identical config file" 1 "$uniq_sums"

hdr "Services on each node"
for id in $(fleet_instances); do
  states="$(node_exec "$id" 'for u in agentgateway agw-echo agw-ratelimit; do printf "%s=%s " $u $(systemctl is-active $u); done; printf "config-sync-timer=%s" $(systemctl is-active agw-config-sync.timer)' 2>/dev/null)"
  printf '  %-20s %s\n' "$id" "$states"
done

hdr "Public endpoints"
expect "GET /whoami"                200 "$(code "$GATEWAY_URL/whoami")"
expect "GET /api/public/headers"    200 "$(code "$GATEWAY_URL/api/public/headers")"
expect "GET /api/private needs a token" 401 "$(code "$GATEWAY_URL/api/private/headers")"
expect "MCP needs a token"          401 "$(code -X POST "$GATEWAY_URL/mcp" -H 'content-type: application/json' -d '{}')"
expect "MCP resource metadata"      200 "$(code "$GATEWAY_URL/.well-known/oauth-protected-resource/mcp")"
expect "MCP DCR route metadata"     200 "$(code "$GATEWAY_URL/.well-known/oauth-protected-resource/mcp-dcr")"
expect "admin UI redirects to Cognito" 302 "$(code "$GATEWAY_URL/ui")"
expect "HTTP redirects to HTTPS"    301 "$(code "http://${GATEWAY_URL#https://}/whoami")"

hdr "Load balancing reaches all three nodes"
log "20 requests to /whoami:"
for _ in $(seq 1 20); do whoami_node; done | sort | uniq -c | sort -rn | sed 's/^/    /'
distinct="$(for _ in $(seq 1 30); do whoami_node; done | sort -u | wc -l | tr -d ' ')"
expect "distinct nodes served traffic" 3 "$distinct"

hdr "Aurora is holding the request log"
writer="$(tf_out aurora_writer_endpoint)"
one_node="$(fleet_instances | head -1)"
rows="$(node_exec "$one_node" "set -a; . /etc/agentgateway/env; set +a; psql \"\$AGW_DATABASE_URL\" -Atc \"select count(*) from information_schema.tables where table_schema='public'\"" 2>/dev/null | tr -d '\n ')"
log "tables in the public schema on $writer: ${rows:-unknown}"
if [[ "${rows:-0}" =~ ^[0-9]+$ ]] && (( rows > 0 )); then
  ok "the request log schema was created on first startup"
else
  warn "could not read the schema; check the node's database connectivity"
fi

hdr "Token minting works"
tok="$(mint_token all)"
expect_contains "access token carries the scopes" "mcp.call" "$(jwt_payload "$tok" | jq -r '.scope // ""')"
expect "authenticated call to /api/private" 200 "$(code -H "authorization: Bearer $tok" "$GATEWAY_URL/api/private/headers")"

summary

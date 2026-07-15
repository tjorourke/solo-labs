#!/usr/bin/env bash
# tools.sh — the headline: the SAME MCP server, seen through two identities.
# Runs tools/list through the gateway once as db-reader and once as db-operator
# and prints the tool set each is allowed. db_reset_credentials appears for the
# operator only.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

GW_SVC="${GW_SVC:-db-gateway}"
kc -n agentgateway-system port-forward "svc/${GW_SVC}" 18080:80 >/tmp/gw-pf.$$ 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:18080/mcp" && break; sleep 1; done
URL="http://localhost:18080/mcp"

for id in reader operator; do
  step "tools/list as db-${id}  (agent: $([[ $id == reader ]] && echo dba-diagnoser || echo sre-remediator))"
  bearer="$(kc -n kagent get secret "agent-token-${id}" -o jsonpath='{.data.authorization}' | base64 -d)"
  python3 "$SCRIPT_DIR/mcpcall.py" "$URL" "$bearer" tools/list
done
echo "" >&2
log "db_reset_credentials is visible to the operator only — filtered from the reader's list by the gateway."

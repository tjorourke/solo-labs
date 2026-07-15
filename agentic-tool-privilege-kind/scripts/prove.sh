#!/usr/bin/env bash
# prove.sh — one agent can do what the other can't. Same tool call
# (db_reset_credentials) attempted with each identity through the gateway:
#   db-reader   -> refused (the gateway filtered/denied the tool)
#   db-operator -> succeeds, and the mock database recovers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

GW_SVC="${GW_SVC:-db-gateway}"
kc -n agentgateway-system port-forward "svc/${GW_SVC}" 18080:80 >/tmp/gw-pf.$$ 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:18080/mcp" && break; sleep 1; done
URL="http://localhost:18080/mcp"
READER="$(kc -n kagent get secret agent-token-reader   -o jsonpath='{.data.authorization}' | base64 -d)"
OPERATOR="$(kc -n kagent get secret agent-token-operator -o jsonpath='{.data.authorization}' | base64 -d)"

step "Before — db_status (as operator): the orders DB is locked"
python3 "$SCRIPT_DIR/mcpcall.py" "$URL" "$OPERATOR" tools/call db_status '{}'

step "db-reader (dba-diagnoser) tries db_reset_credentials -> expect REFUSED"
python3 "$SCRIPT_DIR/mcpcall.py" "$URL" "$READER" tools/call db_reset_credentials '{"new_password":"reader-should-not-do-this"}'

step "db-operator (sre-remediator) calls db_reset_credentials -> expect SUCCESS"
python3 "$SCRIPT_DIR/mcpcall.py" "$URL" "$OPERATOR" tools/call db_reset_credentials '{"new_password":"orders-strong-pw-2026"}'

step "After — db_status (as operator): the orders DB is healthy"
python3 "$SCRIPT_DIR/mcpcall.py" "$URL" "$OPERATOR" tools/call db_status '{}'
echo "" >&2

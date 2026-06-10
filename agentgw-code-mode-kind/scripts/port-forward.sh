#!/usr/bin/env bash
# port-forward.sh — gateway → http://localhost:18770. The MCP endpoint is then at
# http://localhost:18770/mcp. Leave this running in one terminal; the other demo
# scripts also bring up their own forward if one isn't already there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SVC="$(gateway_service)"
[[ -n "$SVC" ]] || die "gateway Service not found — is the lab up? (./scripts/quick.sh status)"
step "gateway ${SVC} → http://localhost:${MCP_LOCAL_PORT}  (MCP at ${MCP_URL}, Ctrl-C to stop)"
exec kc -n "$AGW_NS" port-forward "svc/${SVC}" "${MCP_LOCAL_PORT}:80"

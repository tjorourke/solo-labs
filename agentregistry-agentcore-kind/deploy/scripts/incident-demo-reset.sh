#!/usr/bin/env bash
# incident-demo-reset.sh — reset the incident-tools UI demo so it can run again.
#
# Removes ONLY what the demo creates (in the reverse order it was created):
#   - Deployment incident-tools-virtual   (virtual-default runtime, /registry/incident-tools)
#   - Deployment incident-tools-kagent    (kagent runtime; also tears down the pod + waypoint)
#   - MCPServer  incident-tools-remote    (the remote/virtual catalogue entry)
#   - MCPServer  incident-tools           (the catalogue entry published from the UI)
#   - Runtime    kagent-demo              (the runtime connection added in the UI)
#
# Leaves everything else alone: kagent itself, the kind-kagent runtime, the
# pre-staged everything-server / my-mcp deployments, my-mcp-virtual, and all
# gateway policies. The incident-tools image stays in the local registry, so
# the next run starts straight at "Create MCP Server" in the UI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

arctl_login

del() { # del <kind> <name>
  if arctl get "$1" "$2" >/dev/null 2>&1; then
    arctl delete "$1" "$2" >/dev/null 2>&1 && ok "deleted $1/$2" || warn "could not delete $1/$2"
  else
    log "$1/$2 not present — skipping"
  fi
}

step "Removing incident-tools demo artifacts"
del deployment incident-tools-virtual
del deployment incident-tools-kagent
del mcpserver  incident-tools-remote
del mcpserver  incident-tools
del runtime    kagent-demo

step "Waiting for the kagent pods to go"
for _ in $(seq 1 30); do
  kc get pods -n kagent 2>/dev/null | grep -q 'incident-tools' || break
  sleep 2
done
kc get pods -n kagent 2>/dev/null | grep -q 'incident-tools' \
  && warn "incident-tools pods still terminating — check: kc get pods -n kagent" \
  || ok "no incident-tools pods left in kagent"

step "State after reset"
{ echo "runtimes:"; arctl get runtimes; echo "mcp servers:"; arctl get mcpservers; echo "deployments:"; arctl get deployments; } 2>/dev/null | sed 's/^/  /' >&2 || true
echo >&2
echo "  Ready to demo again: UI -> Runtimes -> Add Runtime Connection (kagent-demo)" >&2

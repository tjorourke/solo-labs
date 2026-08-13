#!/usr/bin/env bash
# Register the in-cluster MCP tool server in AgentRegistry and deploy it to kagent, the
# same way scripts/ar-agent.sh registers and deploys the agent: everything is published
# THROUGH the registry, nothing is hand-applied to kagent.
#
#   ./scripts/ar-mcp.sh register   arctl apply the MCPServer catalogue entry
#   ./scripts/ar-mcp.sh deploy      arctl apply the Deployment (binds it to the kagent runtime)
#   ./scripts/ar-mcp.sh verify      show it in AR and in kagent, with the discovered tools
#   ./scripts/ar-mcp.sh all         register + deploy + verify
#
# The server itself is yaml/60-mcp-tools.yaml (a FastMCP streamable-http server in the
# mcp-tools namespace). Here it is registered as a REMOTE MCP server: AR catalogues it and
# kagent connects to it over the mesh at its in-cluster URL.
#
# One wrinkle worth knowing. When AR deploys a *remote* MCP server (spec.remote) to a bare
# kagent runtime, it writes the server NAME into the kagent RemoteMCPServer's spec.url,
# because the real URL is meant to be filled in by a gateway-rewrite step that only runs
# when the runtime fronts MCP through an agentgateway. A runtime that talks straight to the
# kagent controller has no such gateway, so the URL comes out as the bare name and kagent
# reports `unsupported protocol scheme ""`. The deploy step below therefore patches the
# RemoteMCPServer's spec.url back to the real in-cluster address after AR creates it. The
# admission policy only guards CREATE of kagent workloads from outside the control plane, so
# this in-place UPDATE of an AR-created resource is allowed, and AR does not reconcile it
# away. Image-based MCP servers (spec.source.package) do not hit this and need no patch.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
REALM=sovereign
AR_NS=agentregistry
KC_NS=keycloak
KAGENT_NS=kagent

# The registered MCP server and where kagent should reach it (the in-cluster Service).
MCP_NAME="${MCP_NAME:-sovereign-tools}"
MCP_URL="${MCP_URL:-http://sovereign-tools.mcp-tools.svc.cluster.local:8080/mcp}"
RUNTIME="${RUNTIME:-sovereign-kagent}"

ARCTL="${ARCTL:-$HOME/.arctl/bin/arctl}"
AR_USER="${AR_USER:-carol}"; AR_PASS="${AR_PASS:-carol}"
[ -x "$ARCTL" ] || { echo "error: arctl not found at $ARCTL" >&2; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }

PF_PIDS=()
pf_up() {
  kc -n "$KC_NS" port-forward svc/keycloak 8085:80 >/tmp/pf-mcp-kc.log 2>&1 & PF_PIDS+=($!)
  kc -n "$AR_NS" port-forward svc/agentregistry-enterprise-server 12121:12121 >/tmp/pf-mcp-ar.log 2>&1 & PF_PIDS+=($!)
  sleep 6
}
pf_down() { for p in "${PF_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; PF_PIDS=(); }
trap pf_down EXIT

token() {
  curl -s -X POST "http://localhost:8085/realms/${REALM}/protocol/openid-connect/token" \
    -d "client_id=ar-ui" -d "username=${AR_USER}" -d "password=${AR_PASS}" \
    -d 'grant_type=password' -d 'scope=openid' \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))'
}

register() {
  export ARCTL_API_BASE_URL=http://localhost:12121 ARCTL_API_TOKEN="$(token)"
  "$ARCTL" apply -f - <<MCP
apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: ${MCP_NAME}
spec:
  title: Sovereign Tools
  description: In-cluster MCP tool server (FastMCP) fronted by agentgateway, per-tool authz by identity
  remote:
    type: streamable-http
    url: ${MCP_URL}
MCP
  "$ARCTL" get mcpservers
}

deploy() {
  export ARCTL_API_BASE_URL=http://localhost:12121 ARCTL_API_TOKEN="$(token)"
  # Bind the registered MCP server to the kagent runtime. AR creates the kagent
  # RemoteMCPServer; see the header for why its spec.url then needs correcting.
  "$ARCTL" apply -f - <<DEPLOY
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: ${MCP_NAME}-kagent
spec:
  targetRef:
    kind: MCPServer
    name: ${MCP_NAME}
  runtimeRef:
    kind: Runtime
    name: ${RUNTIME}
DEPLOY
  echo "==> correcting the kagent RemoteMCPServer url to the real in-cluster address"
  for _ in $(seq 1 30); do
    kc -n "$KAGENT_NS" get remotemcpserver "$MCP_NAME" >/dev/null 2>&1 && break; sleep 2
  done
  kc -n "$KAGENT_NS" patch remotemcpserver "$MCP_NAME" --type merge \
    -p "{\"spec\":{\"url\":\"${MCP_URL}\"}}" >/dev/null 2>&1 || true
}

verify() {
  echo "== AR catalogue"
  export ARCTL_API_BASE_URL=http://localhost:12121 ARCTL_API_TOKEN="$(token)"
  "$ARCTL" get mcpservers 2>/dev/null
  echo "== kagent RemoteMCPServer + discovered tools"
  kc -n "$KAGENT_NS" get remotemcpserver "$MCP_NAME" -o jsonpath='{.metadata.name}{"  url="}{.spec.url}{"  accepted="}{.status.conditions[0].status}{"\n"}' 2>/dev/null
  kc -n "$KAGENT_NS" get remotemcpserver "$MCP_NAME" -o json 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);t=d.get("status",{}).get("tools") or [];print("   tools:", ", ".join(x.get("name","") for x in t) or "(none yet)")'
}

case "${1:-all}" in
  register) pf_up; register ;;
  deploy)   pf_up; deploy ;;
  verify)   pf_up; verify ;;
  all)      pf_up; register; deploy; sleep 20; verify ;;
  *) echo "usage: $0 {register|deploy|verify|all}"; exit 1 ;;
esac

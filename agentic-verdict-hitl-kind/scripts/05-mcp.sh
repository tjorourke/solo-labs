#!/usr/bin/env bash
# 05-mcp.sh — the MCP server the agents share, and its route.
#
# Everything applied here belongs to the PLATFORM team. The developer's agents do
# not exist yet (phase 06) and will never reference any of it by name.
#
# One endpoint, one tool set, and all three agents get the same URL. The approval
# decision is not expressed anywhere in this phase: it is enforced inside kagent and
# the agent's own toolsets, so there is no gate to put in front of the server and no
# second route to send a red agent down.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_docker
[[ -n "${LB:-}" ]] || die "LB not set — run ./scripts/02-agentgateway.sh first"

# ── image ─────────────────────────────────────────────────────────────────────
step "Building + loading the sre-tools image"
build_and_load "$LAB_ROOT/src/sre-tools" "$SRE_TOOLS_IMAGE"

# ── MCP server ────────────────────────────────────────────────────────────────
step "Deploying the sre-tools MCP server"
kc apply -f "$LAB_ROOT/yaml/mcp/deployment.yaml" >/dev/null
wait_deploy "$SRE_NS" sre-tools && ok "sre-tools Ready"

# ── the route ─────────────────────────────────────────────────────────────────
step "Applying the MCP route"
sed "s/__LB__/${LB}/g" "$LAB_ROOT/yaml/agentgateway/10-mcp-routes.yaml" \
  | kc apply -f - >/dev/null
# An HTTPRoute's Accepted condition lives under status.parents[].conditions, NOT
# at the top level, so `kubectl wait --for=condition=Accepted` can never see it and
# always times out. Read the nested condition instead.
acc=""
for _ in $(seq 1 20); do
  acc="$(kc -n "$SRE_NS" get httproute mcp-open \
    -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  [[ "$acc" == *"True"* ]] && break
  sleep 3
done
[[ "$acc" == *"True"* ]] && ok "HTTPRoute mcp-open Accepted" \
  || warn "HTTPRoute mcp-open not Accepted (${acc:-no status}) — check: kc -n $SRE_NS describe httproute mcp-open"

# ── prove the server before any agent exists ──────────────────────────────────
# Driving the route with curl separates "the platform works" from "the agent works".
# If this check fails, the problem is the gateway or the MCP pod, not the agent.
step "Proving the route with curl (no agent involved)"
MCP_URL="http://${MCP_HOST}"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

log "POST ${MCP_URL}/mcp (initialize)"
if curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "${MCP_URL}/mcp" \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d "$INIT" | grep -qE '^2'; then
  ok "the MCP server answers through the gateway"
else
  warn "no 2xx — check the gateway and the MCP pod"
fi

# The tool list the register is written against. Printing it here makes the register
# in phase 07 checkable: every name in `gated` should appear below.
step "Tools this server exposes"
kc -n "$SRE_NS" exec deploy/sre-tools -- python3 -c "
import urllib.request, json
d = json.load(urllib.request.urlopen('http://localhost:8080/state', timeout=5))
print('  deployments: %s' % ', '.join(d['deployments']))
" 2>/dev/null >&2 || true
for t in list_pods get_pod_logs describe_deployment restart_deployment scale_deployment; do
  case "$t" in
    restart_deployment|scale_deployment) printf '  %-22s changes state\n' "$t" >&2 ;;
    *)                                   printf '  %-22s read only\n'    "$t" >&2 ;;
  esac
done

step "Platform side ready"
echo "  MCP   : http://${MCP_HOST}/mcp" >&2
echo "  Next  : ./scripts/06-agents.sh" >&2

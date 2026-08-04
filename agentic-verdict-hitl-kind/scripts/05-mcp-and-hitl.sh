#!/usr/bin/env bash
# 05-mcp-and-hitl.sh — the MCP server, the approval gate, the two routes and the
# HITL policy.
#
# Everything applied here belongs to the PLATFORM team. The developer's agents do
# not exist yet (phase 06) and will never reference any of it by name.
#
# Builds and kind-loads three images: sre-tools, hitl-extauth, hitl-ui.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_docker
[[ -n "${LB:-}" ]] || die "LB not set — run ./scripts/02-agentgateway.sh first"

# ── images ────────────────────────────────────────────────────────────────────
step "Building + loading the three service images"
build_and_load "$LAB_ROOT/src/sre-tools"     "$SRE_TOOLS_IMAGE"
build_and_load "$LAB_ROOT/src/hitl-extauth"  "$HITL_EXTAUTH_IMAGE"
build_and_load "$LAB_ROOT/src/hitl-ui"       "$HITL_UI_IMAGE"

# ── MCP server ────────────────────────────────────────────────────────────────
step "Deploying the sre-tools MCP server"
kc apply -f "$LAB_ROOT/yaml/mcp/deployment.yaml" >/dev/null
wait_deploy "$SRE_NS" sre-tools && ok "sre-tools Ready"

# ── approval gate + queue UI ──────────────────────────────────────────────────
step "Deploying the approval gate (hitl-extauth) and queue UI (hitl-ui)"
kc apply -f "$LAB_ROOT/yaml/hitl/extauth.yaml" >/dev/null
sed "s/__LB__/${LB}/g" "$LAB_ROOT/yaml/hitl/ui.yaml" | kc apply -f - >/dev/null
wait_deploy "$HITL_NS" hitl-extauth && ok "hitl-extauth Ready"
wait_deploy "$HITL_NS" hitl-ui      && ok "hitl-ui Ready"

# ── the two routes ────────────────────────────────────────────────────────────
step "Applying the two MCP routes (/mcp open, /mcp-gated gated)"
sed "s/__LB__/${LB}/g" "$LAB_ROOT/yaml/agentgateway/10-mcp-routes.yaml" \
  | kc apply -f - >/dev/null
for r in mcp-open mcp-gated; do
  kc -n "$SRE_NS" wait --for=condition=Accepted "httproute/$r" --timeout=60s >/dev/null 2>&1 \
    && ok "HTTPRoute $r accepted" || warn "HTTPRoute $r not accepted yet"
done

# ── the gate policy ───────────────────────────────────────────────────────────
step "Applying the HITL policy (attached by label, not by name)"
kc apply -f "$LAB_ROOT/yaml/agentgateway/20-hitl-policy.yaml" >/dev/null
sleep 3
ACC="$(kc -n "$SRE_NS" get enterpriseagentgatewaypolicy mcp-hitl-gate \
  -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
ATT="$(kc -n "$SRE_NS" get enterpriseagentgatewaypolicy mcp-hitl-gate \
  -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Attached")].status}' 2>/dev/null)"
log "policy status: Accepted=${ACC:-?} Attached=${ATT:-?}"
[[ "$ACC" == *"True"* ]] || warn "policy not Accepted — check: kc -n $SRE_NS describe eagpol mcp-hitl-gate"

# ── prove the gate before any agent exists ────────────────────────────────────
# Driving the two routes with curl separates "the gate works" from "the agent
# works". If this check fails, the problem is the gateway, not the agent.
step "Proving both routes with curl (no agent involved)"
MCP_URL="http://${MCP_HOST}"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

log "open route  → POST ${MCP_URL}/mcp"
if curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "${MCP_URL}/mcp" \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d "$INIT" | grep -qE '^2'; then
  ok "open route answers (ungated)"
else
  warn "open route did not answer 2xx — check the gateway and the MCP pod"
fi

log "gated route → POST ${MCP_URL}/mcp-gated (expect it to PARK, so this times out)"
GATED_CODE="$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST "${MCP_URL}/mcp-gated" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d "$INIT" 2>/dev/null || echo "timeout")"
PENDING="$(kc -n "$HITL_NS" exec deploy/hitl-extauth -- \
  wget -qO- http://localhost:8081/pending 2>/dev/null | tr -d '\n' || echo '')"
if [[ "$GATED_CODE" == "timeout" || "$GATED_CODE" == "000" ]]; then
  ok "gated route parked the call (curl timed out, which is the expected result)"
else
  warn "gated route returned ${GATED_CODE} instead of parking — is the policy Attached?"
fi
[[ -n "$PENDING" && "$PENDING" != "[]" ]] \
  && ok "the parked call is visible in the approval queue" \
  || log "queue now empty (the parked call was released when curl gave up)"

step "Platform side ready"
echo "  MCP open   : http://${MCP_HOST}/mcp" >&2
echo "  MCP gated  : http://${MCP_HOST}/mcp-gated" >&2
echo "  Approvals  : http://hitl.${LB}.sslip.io" >&2
echo "  Next       : ./scripts/06-agents.sh" >&2

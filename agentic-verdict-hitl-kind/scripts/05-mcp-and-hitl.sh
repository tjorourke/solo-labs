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
# An HTTPRoute's Accepted condition lives under status.parents[].conditions, NOT
# at the top level, so `kubectl wait --for=condition=Accepted` can never see it and
# always times out. Read the nested condition instead.
for r in mcp-open mcp-gated; do
  acc=""
  for _ in $(seq 1 20); do
    acc="$(kc -n "$SRE_NS" get httproute "$r" \
      -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
    [[ "$acc" == *"True"* ]] && break
    sleep 3
  done
  [[ "$acc" == *"True"* ]] && ok "HTTPRoute $r Accepted" \
    || warn "HTTPRoute $r not Accepted (${acc:-no status}) — check: kc -n $SRE_NS describe httproute $r"
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
# The gate only parks tools/call frames. initialize and tools/list pass straight
# through on purpose: parking the handshake would deadlock the MCP session before
# the agent ever got a tool list. So the proof has to be a real tool call, and a
# MUTATING one, since that is what a reviewer is there to decide on.
CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"restart_deployment","arguments":{"name":"checkout","namespace":"shop"}}}'

log "open route  → POST ${MCP_URL}/mcp (initialize)"
if curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "${MCP_URL}/mcp" \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d "$INIT" | grep -qE '^2'; then
  ok "open route answers (ungated)"
else
  warn "open route did not answer 2xx — check the gateway and the MCP pod"
fi

log "gated route → POST ${MCP_URL}/mcp-gated (tools/call — expect it to PARK)"
# Fire it in the background: a parked call does not return, which is the point.
curl -s -m 20 -o /dev/null -X POST "${MCP_URL}/mcp-gated" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d "$CALL" >/dev/null 2>&1 &
GATED_PID=$!
sleep 6

PENDING="$(pending_list)"
if [[ "$PENDING" != "[]" ]]; then
  ok "the call is parked and visible in the approval queue"
  printf '%s' "$PENDING" | python3 -c '
import sys, json
for p in json.load(sys.stdin):
    args = p.get("toolArgs") or {}
    a = ", ".join("%s=%s" % (k, v) for k, v in args.items())
    print("      %s  %s(%s)" % (p.get("id"), p.get("toolName"), a))
' >&2 2>/dev/null || true

  # Reject it, to prove a denial never reaches the MCP server. The mock cluster's
  # audit log is the evidence: a rejected restart leaves no entry.
  for id in $(pending_ids); do
    extauth_admin "/decide/$id" POST '{"approved":false,"reason":"phase 05 proof — rejected"}' >/dev/null
  done
  ok "rejected it, so the mutation never reached the tool server"
else
  warn "nothing parked — the gate did not fire. Check: kc -n $HITL_NS logs deploy/hitl-extauth"
fi
wait "$GATED_PID" 2>/dev/null || true

# Confirm the rejected restart left no trace upstream.
AUDIT="$(kc -n "$SRE_NS" exec deploy/sre-tools -- python3 -c \
  "import urllib.request,json;print(len(json.load(urllib.request.urlopen('http://localhost:8080/state',timeout=5))['audit']))" 2>/dev/null || echo '?')"
if [[ "$AUDIT" == "0" ]]; then
  ok "MCP server audit log is empty — the rejected call never landed"
else
  log "MCP server audit entries: ${AUDIT} (expected 0 on a clean run)"
fi

step "Platform side ready"
echo "  MCP open   : http://${MCP_HOST}/mcp" >&2
echo "  MCP gated  : http://${MCP_HOST}/mcp-gated" >&2
echo "  Approvals  : http://hitl.${LB}.sslip.io" >&2
echo "  Next       : ./scripts/06-agents.sh" >&2

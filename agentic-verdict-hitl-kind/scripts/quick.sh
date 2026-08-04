#!/usr/bin/env bash
# quick.sh — orchestrator. `up` runs every phase in order; each phase is
# idempotent, so a re-run skips what is already done.
#
#   ./scripts/quick.sh up         stand the whole thing up (~15-20 min cold)
#   ./scripts/quick.sh status     what is running, and which agent is gated
#   ./scripts/quick.sh reset      reset the mock cluster
#   ./scripts/quick.sh down       delete the kind cluster and the registry
#
# Approvals are kagent's own, for both agent types, so they are decided in the
# Solo Enterprise UI or over kagent's API:
#   ./scripts/approve.sh srenative "restart checkout" [approve|reject]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PHASES=(
  01-cluster.sh
  02-agentgateway.sh
  03-keycloak.sh
  04-kagent-registry.sh
  05-mcp.sh
  06-agents.sh
  07-verdict.sh
)

cmd_up() {
  require_secrets
  local start; start=$(date +%s)
  for p in "${PHASES[@]}"; do
    step "PHASE ${p%%-*} — $p"
    "$SCRIPT_DIR/$p" || die "phase $p failed"
  done
  step "Up in $(( ($(date +%s) - start) / 60 ))m"
  cmd_status
}

cmd_status() {
  step "Cluster"
  kc get nodes --no-headers 2>/dev/null | sed 's/^/  /' >&2 || die "cluster not reachable"

  step "Control planes"
  for nsdep in "$AGW_NS:enterprise-agentgateway" "$KAGENT_NS:kagent-controller" \
               "$AR_NS:$AR_SERVER_SVC" "kyverno:kyverno-admission-controller" \
               "$SRE_NS:sre-tools" "solo-mgmt:solo-enterprise-ui"; do
    ns="${nsdep%%:*}"; dep="${nsdep##*:}"
    ready="$(kc -n "$ns" get deploy "$dep" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"
    printf '  %-46s %s\n' "$ns/$dep" "${ready:-absent}" >&2
  done

  step "The risk register"
  # Capture then print. Writing `2>/dev/null >&2` sends stderr to /dev/null and
  # THEN points stdout at the same place, so the whole thing prints nothing while
  # still exiting 0 — the section just silently vanishes.
  local reg
  reg="$(kc -n kyverno get configmap agent-risk-register -o json 2>/dev/null)"
  if [[ -n "$reg" ]]; then
    printf '%s' "$reg" | python3 -c '
import sys, json
d = json.load(sys.stdin).get("data", {})
print("  red     = %s" % (d.get("red") or "(none)"))
print("  default = %s" % (d.get("default") or "green"))
g = (d.get("gated") or "").strip()
print("  gated   =")
for line in (g.splitlines() or ["(nothing)"]):
    print("    %s" % line)
' >&2 2>/dev/null || true
  else
    log "no register yet — run ./scripts/07-verdict.sh"
  fi

  step "Agents, and how each one is actually gated"
  printf '  %-14s %-12s %-8s %-7s %s\n' "AGENT" "TYPE" "VERDICT" "READY" "HOW IT IS GATED" >&2
  for a in "$GREEN_AGENT" "$RED_AGENT" "$NATIVE_AGENT"; do
    kc -n "$KAGENT_NS" get agent "$a" >/dev/null 2>&1 \
      || { printf '  %-14s %s\n' "$a" "not deployed" >&2; continue; }
    typ="$(kc -n "$KAGENT_NS" get agent "$a" -o jsonpath='{.spec.type}' 2>/dev/null)"
    verdict="$(kc -n "$KAGENT_NS" get agent "$a" -o jsonpath="{.metadata.labels.risk\.platform\.solo\.io/verdict}" 2>/dev/null)"
    ready="$(kc -n "$KAGENT_NS" get deploy "$a" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"
    if [[ "$typ" == "Declarative" ]]; then
      ra="$(kc -n "$KAGENT_NS" get agent "$a" -o jsonpath='{.spec.declarative.tools[0].mcpServer.requireApproval}' 2>/dev/null)"
      how="${ra:-not gated}"
      [[ -n "$ra" ]] && how="kagent requireApproval $ra"
    else
      # A BYO agent carries its gating in an env var, because kagent cannot see
      # its tools. Same approval card either way.
      ra="$(kc -n "$KAGENT_NS" get agent "$a" -o jsonpath='{.spec.byo.deployment.env[?(@.name=="KAGENT_REQUIRE_APPROVAL")].value}' 2>/dev/null)"
      how="not gated"
      [[ -n "$ra" ]] && how="KAGENT_REQUIRE_APPROVAL=$ra"
    fi
    printf '  %-14s %-12s %-8s %-7s %s\n' "$a" "${typ:-?}" "${verdict:-none}" "${ready:-0/0}" "$how" >&2
  done

  step "The verdict policy"
  kc get clusterpolicy verdict-hitl-enrolment \
    -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
    --no-headers 2>/dev/null | sed 's/^/  /' >&2 || log "verdict policy not applied"

  [[ -n "${LB:-}" ]] && cat >&2 <<EOF

  Enterprise UI     http://kagent.${LB}.sslip.io      (approvals, both agent types)
  AgentRegistry     http://${AR_HOST}
  MCP               http://${MCP_HOST}/mcp
EOF
}

cmd_reset() {
  step "Resetting the mock cluster state"
  # The sre-tools image is python:slim so it does have a shell, but it has no curl.
  # Use the interpreter that is definitely there.
  kc -n "$SRE_NS" exec -i deploy/sre-tools -- python3 -c \
    "import urllib.request;urllib.request.urlopen(urllib.request.Request('http://localhost:8080/reset',b''),timeout=5)" \
    >/dev/null 2>&1 && ok "sre-tools state reset" || warn "could not reset sre-tools"
}

cmd_down() {
  step "Deleting the kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 && ok "cluster deleted" || log "no cluster"
  # The registry is shared with other labs by convention, so leave it unless asked.
  if [[ "${REMOVE_REGISTRY:-0}" == "1" ]]; then
    docker rm -f "$REG_NAME" >/dev/null 2>&1 && ok "registry removed"
  else
    log "registry '$REG_NAME' left running (REMOVE_REGISTRY=1 to remove it)"
  fi
  rm -f "$LAB_ROOT/.env.verdict" "$LAB_ROOT/.env.oidc"
  ok "generated env files removed"
}

case "${1:-up}" in
  up)      cmd_up ;;
  status)  cmd_status ;;
  reset)   cmd_reset ;;
  # `teardown` is the verb labs.manifest.json defaults to; `down` is the one
  # that reads naturally at a prompt. Both, so the E2E runner and a human agree.
  down|teardown) cmd_down ;;
  *) die "usage: $0 {up|status|reset|down}" ;;
esac

#!/usr/bin/env bash
# quick.sh — orchestrator. `up` runs every phase in order; each phase is
# idempotent, so a re-run skips what is already done.
#
#   ./scripts/quick.sh up         stand the whole thing up (~15-20 min cold)
#   ./scripts/quick.sh status     what is running, and which agent is gated
#   ./scripts/quick.sh pending    what is sitting in the approval queue
#   ./scripts/quick.sh approve    approve everything currently parked
#   ./scripts/quick.sh reject     reject everything currently parked
#   ./scripts/quick.sh reset      reset the mock cluster + clear the queue
#   ./scripts/quick.sh down       delete the kind cluster and the registry

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PHASES=(
  01-cluster.sh
  02-agentgateway.sh
  03-keycloak.sh
  04-kagent-registry.sh
  05-mcp-and-hitl.sh
  06-agents.sh
  07-verdict.sh
)

# extauth_admin — run a curl against the ext-auth admin API from inside the pod,
# so no port-forward is needed.
extauth_admin() {
  local path="$1" method="${2:-GET}" data="${3:-}"
  local args=(-s -X "$method" "http://localhost:8081${path}")
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
  kc -n "$HITL_NS" exec -i deploy/hitl-extauth -- curl "${args[@]}" 2>/dev/null
}

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
               "$SRE_NS:sre-tools" "$HITL_NS:hitl-extauth" "$HITL_NS:hitl-ui"; do
    ns="${nsdep%%:*}"; dep="${nsdep##*:}"
    ready="$(kc -n "$ns" get deploy "$dep" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"
    printf '  %-46s %s\n' "$ns/$dep" "${ready:-absent}" >&2
  done

  step "The risk register"
  kc -n kyverno get configmap agent-risk-register \
    -o jsonpath='  red     = {.data.red}{"\n"}  default = {.data.default}{"\n"}  lb      = {.data.lb}{"\n"}' 2>/dev/null >&2 \
    || log "no register yet — run ./scripts/07-verdict.sh"

  step "Agents, and how each one is actually wired"
  printf '  %-14s %-8s %-8s %s\n' "AGENT" "VERDICT" "READY" "MCP URL" >&2
  for a in "$GREEN_AGENT" "$RED_AGENT"; do
    kc -n "$KAGENT_NS" get agent "$a" >/dev/null 2>&1 || { printf '  %-14s %s\n' "$a" "not deployed" >&2; continue; }
    verdict="$(kc -n "$KAGENT_NS" get agent "$a" -o jsonpath="{.metadata.labels.risk\.platform\.solo\.io/verdict}" 2>/dev/null)"
    ready="$(kc -n "$KAGENT_NS" get deploy "$a" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"
    url="$(kc -n "$KAGENT_NS" get agent "$a" -o jsonpath='{.spec.byo.deployment.env[?(@.name=="MCP_SERVERS_CONFIG")].value}' 2>/dev/null \
      | python3 -c 'import sys,json;d=sys.stdin.read().strip();print(json.loads(d)[0]["url"] if d else "(unset)")' 2>/dev/null || echo "?")"
    printf '  %-14s %-8s %-8s %s\n' "$a" "${verdict:-none}" "${ready:-0/0}" "$url" >&2
  done

  step "Gateway policy"
  kc -n "$SRE_NS" get enterpriseagentgatewaypolicy mcp-hitl-gate \
    -o custom-columns='NAME:.metadata.name,ACCEPTED:.status.ancestors[*].conditions[?(@.type=="Accepted")].status' \
    --no-headers 2>/dev/null | sed 's/^/  /' >&2 || log "HITL policy not applied"

  [[ -n "${LB:-}" ]] && cat >&2 <<EOF

  Approvals queue   http://hitl.${LB}.sslip.io
  AgentRegistry     http://${AR_HOST}
  MCP (open/gated)  http://${MCP_HOST}/mcp  ·  /mcp-gated
EOF
}

cmd_pending() {
  step "Parked in the approval queue"
  local out; out="$(extauth_admin /pending)"
  if [[ -z "$out" || "$out" == "[]" ]]; then
    log "nothing parked"
    return 0
  fi
  printf '%s' "$out" | python3 -c '
import sys, json
for p in json.load(sys.stdin):
    tool = p.get("toolName") or p.get("rpcMethod") or "?"
    args = p.get("toolArgs") or {}
    a = ", ".join("%s=%s" % (k, v) for k, v in args.items()) if isinstance(args, dict) else ""
    print("  %s  %s(%s)  path=%s" % (p.get("id"), tool, a, p.get("path", "")))
' 2>/dev/null >&2 || printf '  %s\n' "$out" >&2
}

# Decide every parked request. `approve` is what you would click in the UI; this
# is the scripted equivalent for a runbook or an E2E test.
cmd_decide() {
  local approved="$1" reason="$2"
  local ids
  ids="$(extauth_admin /pending | python3 -c 'import sys,json;print(" ".join(p["id"] for p in json.load(sys.stdin)))' 2>/dev/null)"
  [[ -n "$ids" ]] || { log "nothing parked to decide"; return 0; }
  for id in $ids; do
    extauth_admin "/decide/$id" POST "{\"approved\":$approved,\"reason\":\"$reason\"}" >/dev/null
    ok "$([[ "$approved" == "true" ]] && echo approved || echo rejected) $id"
  done
}

cmd_reset() {
  step "Resetting the mock cluster state"
  kc -n "$SRE_NS" exec -i deploy/sre-tools -- \
    curl -s -X POST http://localhost:8080/reset >/dev/null 2>&1 \
    && ok "sre-tools state reset" || warn "could not reset sre-tools"
  cmd_decide false "reset"
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
  pending) cmd_pending ;;
  approve) cmd_decide true  "approved via quick.sh" ;;
  reject)  cmd_decide false "rejected via quick.sh" ;;
  reset)   cmd_reset ;;
  # `teardown` is the verb labs.manifest.json defaults to; `down` is the one
  # that reads naturally at a prompt. Both, so the E2E runner and a human agree.
  down|teardown) cmd_down ;;
  *) die "usage: $0 {up|status|pending|approve|reject|reset|down}" ;;
esac

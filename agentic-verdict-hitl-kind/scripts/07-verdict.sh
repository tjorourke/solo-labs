#!/usr/bin/env bash
# 07-verdict.sh — THE PLATFORM TEAM'S PHASE.
#
# An external review process has finished. It decided sreremediate is higher risk
# than sretriage — same code, but it is the one wired to act on production, and
# whoever reviewed it wants a human in front of its changes.
#
# The developer is not involved. Nobody edits an agent, rebuilds an image, or
# republishes to the catalogue. Three things happen:
#
#   1. The verdict is written to the risk register (a ConfigMap).
#   2. The restricted AI backend is created (the prompt-injection layer).
#   3. The Kyverno policy is applied, so admission redirects red agents.
#
# Then the two Agent CRs are re-admitted and the difference is shown.
#
# Set VERDICT_RED to a comma-separated list to change who is red:
#   VERDICT_RED="" ./scripts/07-verdict.sh              # clear all verdicts
#   VERDICT_RED="sretriage,sreremediate" ./scripts/07-verdict.sh
#
# Or flip the default posture, so agents are gated unless explicitly cleared:
#   VERDICT_DEFAULT=red ./scripts/07-verdict.sh         # deny-by-default platform

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets     # the gateway needs the upstream model key for the AI backend
[[ -n "${LB:-}" ]] || die "LB not set — run ./scripts/02-agentgateway.sh first"
VERDICT_RED="${VERDICT_RED-$RED_AGENT,$NATIVE_AGENT}"
VERDICT_DEFAULT="${VERDICT_DEFAULT:-green}"

# ── 1. the external review's output ───────────────────────────────────────────
step "Writing the risk register"
log "red list: ${VERDICT_RED:-(empty)}"
log "default posture: ${VERDICT_DEFAULT}"
# The register holds the DECISION and nothing else. Two keys:
#   red      comma-separated agent names that need a human
#   default  posture for everything not named. `red` means every agent needs
#            approval unless explicitly cleared, which is the correct direction
#            for a control. Set VERDICT_DEFAULT=red to demo that.
#
# Addresses deliberately live in a SEPARATE ConfigMap (below). An earlier version
# put the cluster's ingress IP in here so the policy could build URLs, which mixed
# a security decision with a deployment detail and meant every cluster had to edit
# the register.
kc -n kyverno create configmap agent-risk-register \
  --from-literal=red="$VERDICT_RED" \
  --from-literal=default="$VERDICT_DEFAULT" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "configmap/agent-risk-register written (the decision)"
log "this is the ONLY place the verdict is recorded — no agent was modified"

# Platform addresses: where a gated agent's tools and model calls should point.
# Same on every agent; changes only when the cluster's ingress changes.
kc -n kyverno create configmap agent-platform-config \
  --from-literal=gatedMcpUrl="http://mcp.${LB}.sslip.io/mcp-gated" \
  --from-literal=restrictedLlmUrl="http://llm.${LB}.sslip.io" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "configmap/agent-platform-config written (the addresses)"

# ── 2. the restricted AI backend ──────────────────────────────────────────────
step "Creating the restricted AI backend (prompt injection at the gateway)"
sed "s/__LB__/${LB}/g" "$LAB_ROOT/yaml/agentgateway/30-restricted-llm.yaml" \
  | kc apply -f - >/dev/null
sleep 3
BACC="$(kc -n "$AGW_NS" get enterpriseagentgatewaybackend restricted-anthropic \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
[[ "$BACC" == "True" ]] && ok "backend restricted-anthropic Accepted" \
  || warn "backend not Accepted (${BACC:-?}) — check: kc -n $AGW_NS describe eagbe restricted-anthropic"

# The gateway needs an upstream key to call Anthropic on the agent's behalf.
kc -n "$AGW_NS" create secret generic anthropic-upstream \
  --from-literal=Authorization="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1 || true

# ── 3. the policy ─────────────────────────────────────────────────────────────
step "Applying the verdict policy"
KPOL_ERR=""
for _ in $(seq 1 12); do
  KPOL_ERR="$(kc apply -f "$LAB_ROOT/yaml/kyverno/20-verdict-hitl.yaml" 2>&1)" && break
  sleep 5
done
kc get clusterpolicy verdict-hitl-enrolment >/dev/null 2>&1 \
  || die "verdict policy failed to apply: ${KPOL_ERR}"
kc wait --for=condition=Ready clusterpolicy/verdict-hitl-enrolment --timeout=60s >/dev/null 2>&1 || true
ok "clusterpolicy/verdict-hitl-enrolment active (BYO agents -> gateway gate)"

# The native path: for Declarative agents, add requireApproval so the approval
# appears in the kagent UI instead of a separate queue.
for _ in $(seq 1 12); do
  KPOL_ERR="$(kc apply -f "$LAB_ROOT/yaml/kyverno/30-native-approval.yaml" 2>&1)" && break
  sleep 5
done
kc get clusterpolicy verdict-native-approval >/dev/null 2>&1 \
  || die "native approval policy failed to apply: ${KPOL_ERR}"
kc wait --for=condition=Ready clusterpolicy/verdict-native-approval --timeout=60s >/dev/null 2>&1 || true
ok "clusterpolicy/verdict-native-approval active (Declarative agents -> kagent UI)"

# ── 4. re-admit the two agents ────────────────────────────────────────────────
# The mutation runs at admission. Both Agent CRs already exist, so they need to
# pass through the webhook again. An annotation bump is the smallest change that
# triggers an UPDATE admission without altering anything the developer owns.
#
# In a real pipeline the verdict would be in the register BEFORE the agent is
# first deployed, and there would be no re-admission step at all. It exists here
# only so the lab can show a before and an after on the same cluster.
step "Re-admitting both Agent CRs so the webhook re-evaluates them"
STAMP="$(date +%s)"
for a in "$GREEN_AGENT" "$RED_AGENT" "$NATIVE_AGENT"; do
  kc -n "$KAGENT_NS" annotate agent "$a" \
    "risk.platform.solo.io/reviewed-at=$STAMP" --overwrite >/dev/null 2>&1 \
    && ok "re-admitted $a" || warn "could not annotate agent/$a"
done

step "Waiting for the redirected agent to roll"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  kc -n "$KAGENT_NS" rollout status "deploy/$a" --timeout=240s >/dev/null 2>&1 \
    && ok "$a rolled" || warn "$a did not report a completed rollout"
done

# ── 5. show the difference ────────────────────────────────────────────────────
step "What the platform team changed, without touching either agent"
printf '\n  %-14s %-8s %s\n' "AGENT" "VERDICT" "MCP URL IN THE RUNNING POD" >&2
printf '  %-14s %-8s %s\n' "──────────────" "───────" "──────────────────────────" >&2
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  verdict="$(kc -n "$KAGENT_NS" get agent "$a" \
    -o jsonpath="{.metadata.labels.risk\.platform\.solo\.io/verdict}" 2>/dev/null)"
  url="$(kc -n "$KAGENT_NS" get agent "$a" \
    -o jsonpath='{.spec.byo.deployment.env[?(@.name=="MCP_SERVERS_CONFIG")].value}' 2>/dev/null \
    | python3 -c 'import sys,json;d=sys.stdin.read().strip();print(json.loads(d)[0]["url"] if d else "(unset)")' 2>/dev/null || echo "(unreadable)")"
  printf '  %-14s %-8s %s\n' "$a" "${verdict:-none}" "$url" >&2
done

printf '\n  %-14s %s\n' "AGENT" "kagent requireApproval (declarative path)" >&2
printf '  %-14s %s\n' "──────────────" "─────────────────────────────────────────" >&2
RA="$(kc -n "$KAGENT_NS" get agent "$NATIVE_AGENT" \
  -o jsonpath='{.spec.declarative.tools[0].mcpServer.requireApproval}' 2>/dev/null)"
printf '  %-14s %s\n' "$NATIVE_AGENT" "${RA:-(none)}" >&2

printf '\n  %-14s %s\n' "AGENT" "MODEL ENDPOINT IN THE RUNNING POD" >&2
printf '  %-14s %s\n' "──────────────" "─────────────────────────────────" >&2
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  base="$(kc -n "$KAGENT_NS" get agent "$a" \
    -o jsonpath='{.spec.byo.deployment.env[?(@.name=="ANTHROPIC_API_BASE")].value}' 2>/dev/null)"
  printf '  %-14s %s\n' "$a" "${base:-api.anthropic.com (default)}" >&2
done

# Prove the developer's source is untouched. If this ever fails, the lab is
# claiming something it is not doing.
step "Confirming the developer's artefacts are unchanged"
grep -q '/mcp"' "$LAB_ROOT/yaml/agents/deployments.yaml" \
  && ok "the developer's deployment still asks for /mcp — unmodified" \
  || warn "the developer's deployment no longer reads /mcp; did something edit it?"

# The meaningful assertion is that the agent has no knowledge of the gated path or
# the restricted model endpoint — not that the word "approval" is absent. The
# template's own comments discuss approval precisely to explain that none is
# implemented, so a naive keyword grep flags the documentation and reads as a
# failure when nothing is wrong.
if grep -qE "mcp-gated|llm\.[0-9]|ANTHROPIC_API_BASE *=" "$LAB_ROOT/artifacts/$RED_AGENT/$RED_AGENT/agent.py"; then
  warn "the red agent's source references the gated path or a hardcoded endpoint"
else
  ok "the red agent's source has no knowledge of the gated route or the restricted backend"
fi

step "Verdict applied"
cat >&2 <<EOF

  Same code. Same catalogue entry. Same image. Different treatment.

  Watch it happen:
    Approvals queue   http://hitl.${LB}.sslip.io
    Ask the green one ./scripts/ask.sh ${GREEN_AGENT} "restart the checkout deployment"
    Ask the red one   ./scripts/ask.sh ${RED_AGENT} "restart the checkout deployment"

  The green agent restarts it. The red one stops and waits for you.
EOF

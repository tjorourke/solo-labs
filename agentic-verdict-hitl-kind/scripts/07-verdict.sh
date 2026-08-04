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
#   2. The Kyverno policy is applied, so admission turns approval on.
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

require_secrets
[[ -n "${LB:-}" ]] || die "LB not set — run ./scripts/02-agentgateway.sh first"
VERDICT_RED="${VERDICT_RED-$RED_AGENT,$NATIVE_AGENT}"
VERDICT_DEFAULT="${VERDICT_DEFAULT:-green}"

# Which tools need a human, per MCP server. Override to gate a whole server without
# naming its tools:
#   VERDICT_GATED='- server: sre-tools
#     tools: ["*"]'
VERDICT_GATED="${VERDICT_GATED-$(cat <<'YAML'
- server: sre-tools
  tools:
    - restart_deployment
    - scale_deployment
YAML
)}"

# ── 1. the external review's output ───────────────────────────────────────────
step "Writing the risk register"
log "red list: ${VERDICT_RED:-(empty)}"
log "default posture: ${VERDICT_DEFAULT}"
# The register holds the DECISION and nothing else. Three keys:
#   red      comma-separated agent names that need a human
#   default  posture for everything not named. `red` means every agent needs
#            approval unless explicitly cleared, which is the correct direction
#            for a control. Set VERDICT_DEFAULT=red to demo that.
#   gated    which tools need approval, per MCP server. `tools: ["*"]` gates every
#            tool a server exposes, so a server with fifty tools is one entry.
#
# `gated` lives here rather than in the policy on purpose. The policy is cluster-wide
# admission control, so changing it is a change-managed event; adding a tool to a
# register entry is not. It also means the policy contains no tool name at all, and
# never needs editing as the fleet grows.
#
# Addresses deliberately live in a SEPARATE ConfigMap (below). An earlier version
# put the cluster's ingress IP in here so the policy could build URLs, which mixed
# a security decision with a deployment detail and meant every cluster had to edit
# the register.
kc -n kyverno create configmap agent-risk-register \
  --from-literal=red="$VERDICT_RED" \
  --from-literal=default="$VERDICT_DEFAULT" \
  --from-literal=gated="$VERDICT_GATED" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "configmap/agent-risk-register written (the decision)"
log "gated tools:"
printf '%s\n' "$VERDICT_GATED" | sed 's/^/      /' >&2
log "this is the ONLY place the verdict is recorded — no agent was modified"


# ── 2. the policy ─────────────────────────────────────────────────────────────
step "Applying the verdict policy"
# The policy discovers the gated route via an apiCall, which needs a read that
# Kyverno lacks by default. Grant it first or the rule errors and agents are
# refused admission.
kc apply -f "$LAB_ROOT/yaml/kyverno/05-rbac.yaml" >/dev/null
ok "Kyverno granted read on Gateway API (for route discovery)"
KPOL_ERR=""
for _ in $(seq 1 12); do
  KPOL_ERR="$(kc apply -f "$LAB_ROOT/yaml/kyverno/20-verdict-hitl.yaml" 2>&1)" && break
  sleep 5
done
kc get clusterpolicy verdict-hitl-enrolment >/dev/null 2>&1 \
  || die "verdict policy failed to apply: ${KPOL_ERR}"
kc wait --for=condition=Ready clusterpolicy/verdict-hitl-enrolment --timeout=60s >/dev/null 2>&1 || true
ok "clusterpolicy/verdict-hitl-enrolment active (both agent types, 4 rules)"


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

step "Waiting for the BYO agents to roll"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  kc -n "$KAGENT_NS" rollout status "deploy/$a" --timeout=240s >/dev/null 2>&1 \
    && ok "$a rolled" || warn "$a did not report a completed rollout"
done

# ── 5. show the difference ────────────────────────────────────────────────────
step "What the platform team changed, without touching either agent"
printf '\n  %-14s %-8s %-12s %s\n' "AGENT" "VERDICT" "TYPE" "TOOLS THAT NOW NEED A HUMAN" >&2
printf '  %-14s %-8s %-12s %s\n' "──────────────" "───────" "────────────" "───────────────────────────" >&2
for a in "$GREEN_AGENT" "$RED_AGENT" "$NATIVE_AGENT"; do
  verdict="$(kc -n "$KAGENT_NS" get agent "$a" \
    -o jsonpath="{.metadata.labels.risk\.platform\.solo\.io/verdict}" 2>/dev/null)"
  typ="$(kc -n "$KAGENT_NS" get agent "$a" -o jsonpath='{.spec.type}' 2>/dev/null)"
  if [[ "$typ" == "Declarative" ]]; then
    # kagent owns the tool list, so the gate is a field on the CR.
    gated="$(kc -n "$KAGENT_NS" get agent "$a" \
      -o jsonpath='{.spec.declarative.tools[0].mcpServer.requireApproval}' 2>/dev/null)"
  else
    # kagent cannot see a BYO agent's tools, so the gate is an env var its own
    # toolsets read. Same approval card either way.
    gated="$(kc -n "$KAGENT_NS" get agent "$a" \
      -o jsonpath='{.spec.byo.deployment.env[?(@.name=="KAGENT_REQUIRE_APPROVAL")].value}' 2>/dev/null)"
  fi
  printf '  %-14s %-8s %-12s %s\n' "$a" "${verdict:-none}" "${typ:-?}" "${gated:-(none)}" >&2
done

# Every MCP URL should be identical. There is one route and nothing redirects, so a
# difference here means something rewrote an agent that should have been left alone.
printf '\n  %-14s %s\n' "AGENT" "MCP URL IN THE RUNNING POD (should be identical)" >&2
printf '  %-14s %s\n' "──────────────" "────────────────────────────────────────────────" >&2
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  url="$(kc -n "$KAGENT_NS" get agent "$a" \
    -o jsonpath='{.spec.byo.deployment.env[?(@.name=="MCP_SERVERS_CONFIG")].value}' 2>/dev/null \
    | python3 -c 'import sys,json;d=sys.stdin.read().strip();print(json.loads(d)[0]["url"] if d else "(unset)")' 2>/dev/null || echo "(unreadable)")"
  printf '  %-14s %s\n' "$a" "$url" >&2
done


# Prove the developer's source is untouched. If this ever fails, the lab is
# claiming something it is not doing.
step "Confirming the developer's artefacts are unchanged"
grep -q '/mcp"' "$LAB_ROOT/yaml/agents/deployments.yaml" \
  && ok "the developer's deployment still asks for /mcp — unmodified" \
  || warn "the developer's deployment no longer reads /mcp; did something edit it?"

# The agent knows the NAMES of its tools — it is told to use them, and its
# instruction text mentions them. What it must not contain is any decision about
# which of them need a human. So assert on the decision, not on the names: a naive
# keyword grep flags the agent's own instructions and reads as a failure when
# nothing is wrong.
SRC="$LAB_ROOT/artifacts/$RED_AGENT/$RED_AGENT/agent.py"
if grep -qE '^[^#]*KAGENT_REQUIRE_APPROVAL[[:space:]]*=' "$SRC"; then
  warn "the red agent's source SETS its own approval list — it must only read it"
else
  ok "the red agent's source never decides which tools need approval"
fi

# And it must carry no hard-coded tool name in that decision: the gated set comes
# from the environment, so the literal names appear nowhere near it.
if grep -n 'KAGENT_REQUIRE_APPROVAL' "$SRC" | grep -qE 'restart_deployment|scale_deployment'; then
  warn "a tool name is hard-coded into the red agent's gating logic"
else
  ok "the gated set comes from the environment, not from the agent"
fi

step "Verdict applied"
cat >&2 <<EOF

  Same code. Same catalogue entry. Same image. Different treatment.

  Watch it happen:
    Enterprise UI     http://kagent.${LB}.sslip.io
    Ask the green one ./scripts/ask.sh ${GREEN_AGENT} "restart the checkout deployment"
    Ask the red one   ./scripts/ask.sh ${RED_AGENT} "restart the checkout deployment"

  The green agent restarts it. The red one stops and waits for you.
EOF

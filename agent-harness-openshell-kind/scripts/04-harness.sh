#!/usr/bin/env bash
# 04-harness.sh — declare the SRE AgentHarness and grant its sandbox kubectl rights.
#
# Steps:
#   1. Anthropic secret + ModelConfig (the model the OpenClaw agent reasons with)
#   2. SRE roles (cluster-wide read, incident-namespace write)
#   3. The AgentHarness itself; wait for Accepted then Ready
#   4. Discover the sandbox pod's ServiceAccount and bind the SRE roles to it,
#      so kubectl inside the sandbox can both triage and fix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Namespaces"
kc apply -f "$LAB_ROOT/yaml/namespaces.yaml" >/dev/null
ok "incident namespace ready"

step "Anthropic secret (kagent ns)"
kc -n kagent create secret generic kagent-anthropic \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "secret kagent-anthropic ready"

step "ModelConfig + SRE roles"
kc apply -f "$LAB_ROOT/yaml/modelconfig.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/sre-rbac.yaml" >/dev/null
ok "ModelConfig + ClusterRole/Role applied"

step "Declaring the AgentHarness"
kc apply -f "$LAB_ROOT/yaml/agentharness.yaml" >/dev/null
ok "AgentHarness sre-oncall applied"

# ── wait for Accepted, then Ready ─────────────────────────────────────────────
harness_cond() {  # $1 = condition type → prints True/False/Unknown/""
  kc -n kagent get agentharness sre-oncall \
    -o jsonpath="{.status.conditions[?(@.type=='$1')].status}" 2>/dev/null
}

step "Waiting for the harness to be Accepted"
end=$(( $(date +%s) + 120 ))
until [[ "$(harness_cond Accepted)" == "True" ]]; do
  [[ $(date +%s) -ge $end ]] && { warn "not Accepted within 2m — current conditions:"; \
    kc -n kagent get agentharness sre-oncall -o jsonpath='{.status.conditions}' >&2; echo >&2; break; }
  sleep 4
done
[[ "$(harness_cond Accepted)" == "True" ]] && ok "Accepted=True"

step "Waiting for the sandbox to be Ready (backend provisions a VM — can take a few min)"
end=$(( $(date +%s) + 420 ))
until [[ "$(harness_cond Ready)" == "True" ]]; do
  [[ $(date +%s) -ge $end ]] && { warn "not Ready within 7m — current conditions:"; \
    kc -n kagent get agentharness sre-oncall -o jsonpath='{.status.conditions}' >&2; echo >&2; break; }
  sleep 6
done
if [[ "$(harness_cond Ready)" == "True" ]]; then
  ok "Ready=True"
else
  warn "harness not Ready — RBAC binding below may find no sandbox pod yet."
  warn "Inspect: kubectl -n kagent describe agentharness sre-oncall"
fi

HID="$(kc -n kagent get agentharness sre-oncall -o jsonpath='{.status.backendRef.id}' 2>/dev/null || true)"
ENDPOINT="$(kc -n kagent get agentharness sre-oncall -o jsonpath='{.status.connection.endpoint}' 2>/dev/null || true)"
[[ -n "$HID" ]] && log "backend id: $HID"
[[ -n "$ENDPOINT" ]] && log "connection endpoint: $ENDPOINT"

# ── discover the sandbox pod's ServiceAccount and bind the SRE roles ───────────
step "Granting the sandbox kubectl rights"
SB_NS="" ; SB_POD="" ; SB_SA=""
# OpenShell builds on the agent-sandbox controller (sandboxes.agents.x-k8s.io).
if kc get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1; then
  SB_NS="$(kc get sandboxes.agents.x-k8s.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  SB_NAME="$(kc get sandboxes.agents.x-k8s.io -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$SB_NS" ]] && log "sandbox: ${SB_NS}/${SB_NAME}"
fi
# Find the backing pod + its ServiceAccount. The sandbox pod name equals the
# Sandbox resource name (its label is a name-hash, not the name), so match by
# name with a substring fallback.
if [[ -n "$SB_NS" ]]; then
  SB_POD="$(kc -n "$SB_NS" get pod "$SB_NAME" -o name 2>/dev/null | sed 's#pod/##' || true)"
  [[ -z "$SB_POD" ]] && SB_POD="$(kc -n "$SB_NS" get pod -o name 2>/dev/null \
            | sed 's#pod/##' | grep -F "$SB_NAME" | head -1 || true)"
  [[ -n "$SB_POD" ]] && SB_SA="$(kc -n "$SB_NS" get pod "$SB_POD" \
            -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null || true)"
fi
# Fallback: the OpenShell chart's sandbox ServiceAccount.
if [[ -z "$SB_SA" ]]; then
  SB_NS="${SB_NS:-$OPENSHELL_NS}"
  SB_SA="openshell-sandbox"
  warn "could not read the sandbox pod's SA — falling back to ${SB_NS}/${SB_SA}"
fi
[[ "$SB_SA" == "default" || -z "$SB_SA" ]] && SB_SA="${SB_SA:-default}"
log "binding SRE roles to ServiceAccount ${SB_NS}/${SB_SA}"

# Cluster-wide READ: the agent may triage anywhere.
kc create clusterrolebinding sre-harness-read \
  --clusterrole=sre-harness-read --serviceaccount="${SB_NS}:${SB_SA}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "sandbox SA ${SB_NS}/${SB_SA} granted cluster-wide read (triage)"

# Label-gated WRITE: bind the fix ClusterRole ONLY in namespaces labeled
# autofix=true. This reconcile is what turns the label into an authz boundary —
# anywhere without it, kubectl patch returns 403. Re-run this script after
# labelling a namespace to extend the agent's fix scope.
step "Reconciling fix permissions for autofix=true namespaces"
AUTOFIX_NS="$(kc get ns -l autofix=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
if [[ -z "$AUTOFIX_NS" ]]; then
  warn "no namespaces labeled autofix=true — the agent can triage but cannot fix anywhere yet"
else
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    kc -n "$ns" create rolebinding sre-harness-fix \
      --clusterrole=sre-harness-fix --serviceaccount="${SB_NS}:${SB_SA}" \
      --dry-run=client -o yaml | kc apply -f - >/dev/null
    ok "fix allowed in '$ns' (autofix=true)"
  done <<< "$AUTOFIX_NS"
fi

step "Harness ready"
echo "  Harness:  kubectl -n kagent get agentharness sre-oncall" >&2
[[ -n "$ENDPOINT" ]] && echo "  Endpoint: $ENDPOINT" >&2
echo "  Next:     ./scripts/05-equip-sandbox.sh" >&2

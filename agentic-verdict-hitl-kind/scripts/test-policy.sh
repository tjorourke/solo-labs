#!/usr/bin/env bash
# test-policy.sh — exercise the verdict policy with the Kyverno CLI, no cluster.
#
# The policy is the control in this lab, so it gets a real test rather than a
# read-through. Four postures plus an idempotence check, all offline.
#
# WHAT THIS COVERS: the decision logic — who gets gated, under which posture, and
# that re-admission does not double-apply. It drives that through the DECLARATIVE
# rule, which needs no cluster.
#
# WHAT IT DOES NOT COVER: the BYO rule's URL discovery. That rule reads the gated
# HTTPRoute with an apiCall, and the Kyverno CLI cannot stub a nested apiCall result
# (`gatedRoute.hostnames[0]` fails with `Unknown key "hostnames"`), while --cluster
# mode only accepts resources already in the cluster, not fixtures. The decision
# logic is shared between both rules, so testing it once here is enough; the BYO
# redirect itself is verified by the live run in scripts/07-verdict.sh, which prints
# the resulting URL from each running pod.
#
# Needs the kyverno CLI matching the lab's KYVERNO_VERSION:
#   brew install kyverno
#   # or: https://github.com/kyverno/kyverno/releases
#
# Run it after ANY edit to yaml/kyverno/20-verdict-hitl.yaml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kyverno
POLICY="$LAB_ROOT/yaml/kyverno/20-verdict-hitl.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

# A Declarative Agent, which is what the tested rule matches. toolNames lists the
# mutating tools, because the CRD's CEL rule means requireApproval can only be added
# when they are already declared. Pass $2 to pre-set requireApproval (idempotence).
agent_cr() {
  cat <<EOF
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: $1
  namespace: kagent
spec:
  type: Declarative
  description: SRE assistant
  declarative:
    runtime: python
    modelConfig: default-model-config
    systemMessage: "..."
    tools:
      - type: McpServer
        mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: sre-tools
          toolNames: [list_pods, get_pod_logs, restart_deployment, scale_deployment]${2:+
          requireApproval: [restart_deployment, scale_deployment]}
EOF
}

# Kyverno CLI stubs the ConfigMap context through a values file.
write_values() {
  local red="$1" def="$2"
  {
    echo "policies:"
    echo "  - name: verdict-hitl-enrolment"
    echo "    rules:"
    # apiCall results are stubbed by variable name — the CLI cannot reach a cluster.
    for r in native-approval-declarative label-red label-green; do
      echo "      - name: $r"
      echo "        values:"
      echo "          register.data.red: \"$red\""
      echo "          register.data.default: \"$def\""
    done
  } > "$WORK/values.yaml"
}

# Reduce each mutated Agent to "<name> <verdict> <approval-or-not>".
summarise() {
  python3 -c "
import sys, yaml
for blk in sys.stdin.read().split('---'):
    if 'kind: Agent' not in blk: continue
    try: d = yaml.safe_load(blk[blk.index('apiVersion:'):])
    except Exception: continue
    if not isinstance(d, dict) or d.get('kind') != 'Agent': continue
    n = d['metadata']['name']
    lbl = (d['metadata'].get('labels') or {}).get('risk.platform.solo.io/verdict', '-')
    ra = (d['spec']['declarative']['tools'][0]['mcpServer'].get('requireApproval') or [])
    print(n, lbl, 'approval' if ra else 'noapproval')
" | sort
}

check() {
  local desc="$1" red="$2" def="$3" expected="$4"
  write_values "$red" "$def"
  { agent_cr sretriage; echo "---"; agent_cr sreremediate; } > "$WORK/agents.yaml"
  local got
  got="$(kyverno apply "$POLICY" --resource "$WORK/agents.yaml" \
         --values-file "$WORK/values.yaml" 2>/dev/null | summarise)"
  if [[ "$got" == "$expected" ]]; then
    ok "$desc"
  else
    warn "$desc"
    printf '      expected:\n%s\n      got:\n%s\n' \
      "$(sed 's/^/        /' <<<"$expected")" "$(sed 's/^/        /' <<<"$got")" >&2
    FAILED=1
  fi
}

step "Verdict policy — posture matrix"

check "red=sreremediate, default=green  → only the named agent is gated" \
  "sreremediate" "green" \
"sreremediate red approval
sretriage green noapproval"

check "red empty, default=red           → fail-closed, everything gated" \
  "" "red" \
"sreremediate red approval
sretriage red approval"

check "red empty, default=green         → nothing gated" \
  "" "green" \
"sreremediate green noapproval
sretriage green noapproval"

check "both named red                   → both gated" \
  "sretriage,sreremediate" "green" \
"sreremediate red approval
sretriage red approval"

step "Idempotence — re-admitting an already-mutated agent"
write_values "sreremediate" "green"
agent_cr sreremediate "yes" > "$WORK/mutated.yaml"
DUPES="$(kyverno apply "$POLICY" --resource "$WORK/mutated.yaml" \
         --values-file "$WORK/values.yaml" 2>/dev/null | python3 -c "
import sys, yaml
from collections import Counter
for blk in sys.stdin.read().split('---'):
    if 'kind: Agent' not in blk: continue
    try: d = yaml.safe_load(blk[blk.index('apiVersion:'):])
    except Exception: continue
    if not isinstance(d, dict) or d.get('kind') != 'Agent': continue
    ra = d['spec']['declarative']['tools'][0]['mcpServer'].get('requireApproval') or []
    print(','.join(k for k, v in Counter(ra).items() if v > 1))
")"
if [[ -z "${DUPES//[[:space:]]/}" ]]; then
  ok "no duplicate requireApproval entries on re-admission"
else
  warn "duplicate requireApproval entries appeared: $DUPES"
  FAILED=1
fi

step "Result"
if (( FAILED )); then
  die "policy tests FAILED"
else
  ok "all policy tests passed"
fi

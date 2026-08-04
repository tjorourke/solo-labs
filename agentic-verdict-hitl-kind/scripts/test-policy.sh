#!/usr/bin/env bash
# test-policy.sh — exercise the verdict policy with the Kyverno CLI, no cluster.
#
# The policy is the control in this lab, so it gets a real test rather than a
# read-through. Two matrices, all offline:
#
#   posture   who gets gated, under which red/default posture
#   register  WHICH tools get gated, driven entirely by the register's `gated` key
#
# The second matrix is the one that matters most, because the policy names no tool.
# If the register lookup breaks, the policy still applies cleanly and still labels
# every agent red — and gates nothing. That is a silent fail-open, so it is tested
# directly rather than inferred from the policy applying without error.
#
# Both agent types are covered. The declarative rule reads toolNames off the CR; the
# BYO rule reads the server names out of the agent's own MCP_SERVERS_CONFIG. Neither
# needs a cluster.
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

# Rule names the values file has to stub. A stale name here is not a test failure,
# it is an untested policy: Kyverno silently leaves the context unresolved, the
# precondition goes false, and every approval assertion fails for the wrong reason.
# Checked against the policy below so it cannot drift again.
RULES=(approval-declarative approval-byo label-red label-green)

for r in "${RULES[@]}"; do
  grep -q "name: $r" "$POLICY" \
    || die "test harness is stale: no rule '$r' in $(basename "$POLICY")"
done

# A Declarative Agent — kagent knows its tools, so requireApproval is the surface.
# toolNames deliberately lists MORE than the register gates, so an over-broad
# mutation shows up. Pass $2 to pre-set requireApproval (idempotence).
declarative_cr() {
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
          toolNames: [list_pods, get_pod_logs, describe_deployment, restart_deployment, scale_deployment]${2:+
          requireApproval: [restart_deployment, scale_deployment]}
EOF
}

# A BYO Agent shaped the way AgentRegistry creates one. Another env var goes FIRST
# on purpose: a fixed-index patch would hit it instead of appending.
byo_cr() {
  cat <<EOF
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: $1
  namespace: kagent
spec:
  type: BYO
  description: SRE assistant
  byo:
    deployment:
      image: localhost:5001/$1:latest
      env:
        - name: MCP_CONNECT_TIMEOUT
          value: "900"
        - name: MCP_SERVERS_CONFIG
          value: '[{"name":"sre-tools","type":"remote","url":"http://mcp.example/mcp"}]'${2:+
        - name: KAGENT_REQUIRE_APPROVAL
          value: "restart_deployment,scale_deployment"}
EOF
}

# Kyverno CLI stubs the ConfigMap context through a values file. Every rule that
# reads the register needs its own stanza.
write_values() {
  local red="$1" def="$2" gated="$3"
  {
    echo "policies:"
    echo "  - name: verdict-hitl-enrolment"
    echo "    rules:"
    for r in "${RULES[@]}"; do
      echo "      - name: $r"
      echo "        values:"
      echo "          register.data.red: \"$red\""
      echo "          register.data.default: \"$def\""
      echo "          register.data.gated: |"
      printf '%s\n' "$gated" | sed 's/^/            /'
    done
  } > "$WORK/values.yaml"
}

# The register entry used by the posture matrix: the two mutating tools.
GATED_DEFAULT='- server: sre-tools
  tools:
    - restart_deployment
    - scale_deployment'

# Reduce each mutated Agent to "<name> <verdict> <gated-tools-or-dash>", so the
# assertions read as the actual outcome rather than "did it mutate".
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
    if d['spec']['type'] == 'Declarative':
        got = d['spec']['declarative']['tools'][0]['mcpServer'].get('requireApproval') or []
    else:
        env = d['spec']['byo']['deployment'].get('env') or []
        v = [e.get('value','') for e in env if e['name'] == 'KAGENT_REQUIRE_APPROVAL']
        got = [t for t in (v[0].split(',') if v else []) if t]
    print(n, lbl, ','.join(got) if got else '-')
" | sort
}

# $1 desc  $2 red  $3 default  $4 gated-yaml  $5 expected
check() {
  local desc="$1" red="$2" def="$3" gated="$4" expected="$5"
  write_values "$red" "$def" "$gated"
  { declarative_cr sretriage; echo "---"; byo_cr sreremediate; } > "$WORK/agents.yaml"
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

step "Posture matrix — WHO gets gated"

check "red=sreremediate, default=green  → only the named agent is gated" \
  "sreremediate" "green" "$GATED_DEFAULT" \
"sreremediate red restart_deployment,scale_deployment
sretriage green -"

check "red empty, default=red           → fail-closed, everything gated" \
  "" "red" "$GATED_DEFAULT" \
"sreremediate red restart_deployment,scale_deployment
sretriage red restart_deployment,scale_deployment"

check "red empty, default=green         → nothing gated" \
  "" "green" "$GATED_DEFAULT" \
"sreremediate green -
sretriage green -"

check "both named red                   → both gated, both types" \
  "sretriage,sreremediate" "green" "$GATED_DEFAULT" \
"sreremediate red restart_deployment,scale_deployment
sretriage red restart_deployment,scale_deployment"

step "Register matrix — WHICH tools get gated, with no tool named in the policy"

check "one tool in the register         → exactly that tool is gated" \
  "sretriage,sreremediate" "green" \
'- server: sre-tools
  tools:
    - scale_deployment' \
"sreremediate red scale_deployment
sretriage red scale_deployment"

check "wildcard                         → every tool the server exposes" \
  "sretriage,sreremediate" "green" \
'- server: sre-tools
  tools: ["*"]' \
"sreremediate red *
sretriage red list_pods,get_pod_logs,describe_deployment,restart_deployment,scale_deployment"

check "a tool the agent does not have   → dropped, so the CR stays CEL-valid" \
  "sretriage,sreremediate" "green" \
'- server: sre-tools
  tools:
    - restart_deployment
    - delete_namespace' \
"sreremediate red restart_deployment,delete_namespace
sretriage red restart_deployment"

check "a different server               → this agent is untouched" \
  "sretriage,sreremediate" "green" \
'- server: payments-tools
  tools:
    - issue_refund' \
"sreremediate red -
sretriage red -"

check "empty register                   → red agents labelled, nothing gated" \
  "sretriage,sreremediate" "green" "[]" \
"sreremediate red -
sretriage red -"

step "Idempotence — re-admitting an already-mutated agent"
write_values "sretriage,sreremediate" "green" "$GATED_DEFAULT"
{ declarative_cr sretriage yes; echo "---"; byo_cr sreremediate yes; } > "$WORK/mutated.yaml"
DUPES="$(kyverno apply "$POLICY" --resource "$WORK/mutated.yaml" \
         --values-file "$WORK/values.yaml" 2>/dev/null | python3 -c "
import sys, yaml
from collections import Counter
for blk in sys.stdin.read().split('---'):
    if 'kind: Agent' not in blk: continue
    try: d = yaml.safe_load(blk[blk.index('apiVersion:'):])
    except Exception: continue
    if not isinstance(d, dict) or d.get('kind') != 'Agent': continue
    n = d['metadata']['name']
    if d['spec']['type'] == 'Declarative':
        items = d['spec']['declarative']['tools'][0]['mcpServer'].get('requireApproval') or []
    else:
        items = [e['name'] for e in (d['spec']['byo']['deployment'].get('env') or [])]
    for k, v in Counter(items).items():
        if v > 1: print('%s: %s x%d' % (n, k, v))
")"
if [[ -z "${DUPES//[[:space:]]/}" ]]; then
  ok "no duplicates on re-admission (requireApproval and env)"
else
  warn "duplicates appeared:"
  sed 's/^/        /' <<<"$DUPES" >&2
  FAILED=1
fi

step "Result"
if (( FAILED )); then
  die "policy tests FAILED"
else
  ok "all policy tests passed"
fi

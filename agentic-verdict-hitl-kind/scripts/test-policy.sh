#!/usr/bin/env bash
# test-policy.sh — exercise the verdict policy with the Kyverno CLI, no cluster.
#
# The policy is the control in this lab, so it gets a real test rather than a
# read-through. Four postures plus an idempotence check, all offline.
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

# Two Agent CRs shaped the way AgentRegistry actually creates them: type BYO,
# MCP_SERVERS_CONFIG not first in the env list (so a fixed-index patch would
# hit the wrong variable and the test would catch it).
agent_cr() {
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
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: http://collector:4318
        - name: MCP_SERVERS_CONFIG
          value: '[{"name":"sre-tools","type":"remote","url":"http://mcp.172.18.255.200.sslip.io/${2:-mcp}"}]'
        - name: MCP_TERMINATE_ON_CLOSE
          value: "false"${3:+
        - name: ANTHROPIC_API_BASE
          value: http://llm.172.18.255.200.sslip.io}
EOF
}

# Kyverno CLI stubs the ConfigMap context through a values file.
write_values() {
  local red="$1" def="$2"
  {
    echo "policies:"
    echo "  - name: verdict-hitl-enrolment"
    echo "    rules:"
    for r in gate-mcp-traffic restrict-model-traffic label-red label-green; do
      echo "      - name: $r"
      echo "        values:"
      echo "          register.data.red: \"$red\""
      echo "          register.data.default: \"$def\""
      echo "          platform.data.gatedMcpUrl: \"http://mcp.test.example/mcp-gated\""
      echo "          platform.data.restrictedLlmUrl: \"http://llm.test.example\""
    done
  } > "$WORK/values.yaml"
}

# Reduce each mutated Agent to "<name> <verdict> <mcp-path> <has-api-base>".
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
    env = {e['name']: e.get('value', '') for e in d['spec']['byo']['deployment']['env']}
    path = 'gated' if '/mcp-gated' in env.get('MCP_SERVERS_CONFIG', '') else 'open'
    base = 'base' if 'ANTHROPIC_API_BASE' in env else 'nobase'
    print(n, lbl, path, base)
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
"sreremediate red gated base
sretriage green open nobase"

check "red empty, default=red           → fail-closed, everything gated" \
  "" "red" \
"sreremediate red gated base
sretriage red gated base"

check "red empty, default=green         → nothing gated" \
  "" "green" \
"sreremediate green open nobase
sretriage green open nobase"

check "both named red                   → both gated" \
  "sretriage,sreremediate" "green" \
"sreremediate red gated base
sretriage red gated base"

step "Idempotence — re-admitting an already-mutated agent"
write_values "sreremediate" "green"
agent_cr sreremediate "mcp-gated" "yes" > "$WORK/mutated.yaml"
DUPES="$(kyverno apply "$POLICY" --resource "$WORK/mutated.yaml" \
         --values-file "$WORK/values.yaml" 2>/dev/null | python3 -c "
import sys, yaml
from collections import Counter
for blk in sys.stdin.read().split('---'):
    if 'kind: Agent' not in blk: continue
    try: d = yaml.safe_load(blk[blk.index('apiVersion:'):])
    except Exception: continue
    if not isinstance(d, dict) or d.get('kind') != 'Agent': continue
    names = [e['name'] for e in d['spec']['byo']['deployment']['env']]
    print(','.join(k for k, v in Counter(names).items() if v > 1))
")"
if [[ -z "${DUPES//[[:space:]]/}" ]]; then
  ok "no duplicate env vars on re-admission"
else
  warn "duplicate env vars appeared: $DUPES"
  FAILED=1
fi

step "Result"
if (( FAILED )); then
  die "policy tests FAILED"
else
  ok "all policy tests passed"
fi

#!/usr/bin/env bash
# compare-modes.sh [N] — ask the agent for the same release report in Standard
# and in Code mode, and report what each cost.
#
# Measures three things per mode, from the A2A trace:
#   calls  — tool calls the MODEL had to make (each one is a round trip, and each
#            re-sends the whole conversation so far)
#   bytes  — tool-response payload that passed THROUGH the model's context
#   secs   — wall clock
#
# Code mode's ceiling is 20 upstream calls per program, so N=9 (1 list + 2 per PR)
# is the largest single-program report.
set -euo pipefail
N="${1:-9}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AR="$HERE/../../agentregistry"
K="kubectl --context kind-mesh1"
REPO="${REPO:-kagent-dev/kagent}"
OWNER="${REPO%/*}"; NAME="${REPO#*/}"
Q="Give me the release report for ${OWNER}/${NAME}, the ${N} most recently opened pull requests."
OUT="${OUT_DIR:-/tmp}/prtriage-compare"; mkdir -p "$OUT"

run_mode() {
  local mode="$1"
  $K -n agentgateway-system patch enterpriseagentgatewaybackend github-mcp \
     --type=merge -p "{\"spec\":{\"entMcp\":{\"toolMode\":\"$mode\"}}}" >/dev/null
  # the agent lists tools once at startup, so it has to re-list to see the change
  $K -n kagent rollout restart deploy/prtriage >/dev/null
  $K -n kagent rollout status deploy/prtriage --timeout=180s >/dev/null
  sleep 5
  local t0 t1
  t0=$(date +%s)
  ( cd "$AR" && AGENT_PREFIX=prtriage ./scripts/ask.sh "$Q" ) > "$OUT/$mode.txt" 2>&1
  t1=$(date +%s)
  python3 - "$OUT/$mode.txt" "$mode" "$((t1-t0))" <<'PY'
import sys,re
path,mode,secs=sys.argv[1],sys.argv[2],sys.argv[3]
txt=open(path).read()
lines=[l for l in txt.splitlines() if re.match(r'^\s+\d+\.\s+\S+\(',l)]
payload=sum(len(l.split('-> ',1)[1]) for l in lines if '-> ' in l)
print("%-9s calls=%-3s payload_through_model=%-8s secs=%s" % (mode,len(lines),payload,secs))
PY
}
echo "asking for the ${N} most recent open PRs on ${REPO}"
run_mode Standard
run_mode Code
echo
echo "answers: $OUT/Standard.txt  $OUT/Code.txt"

#!/usr/bin/env bash
# compare-modes.sh [modes...] — run the same question through each toolMode and report
# what it cost. Defaults to the two the demo does not show live.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASK="$HERE/../../../demo-scripts/agentregistry/scripts/ask.sh"
REPO="${DEMO_REPO:-tjorourke/kagent}"
Q="${Q:-Give me the release report for $REPO, all open pull requests.}"
for m in "${@:-Search Code}"; do
  "$HERE/set-mode.sh" "$m" >/dev/null
  echo "### $m"
  AGENT_PREFIX=prtriagejava "$ASK" "$Q" > "/tmp/run-$m.txt" 2>&1
  "$HERE/trace-cost.sh" "/tmp/run-$m.txt"
  grep -E "^Ready:" "/tmp/run-$m.txt" | head -1 | sed 's/^/  /'
done

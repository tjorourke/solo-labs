#!/usr/bin/env bash
# try-merge.sh <agent-deployment> [pullNumber] — ask the gateway to merge, as that agent.
#
# This is the enforcement proof, and it deliberately does NOT go through the model. An
# agent saying "I cannot merge" is the model being agreeable. This is the call the model
# would have made, sent straight at the gateway from inside the agent's own pod, so it
# carries the agent's real mesh identity and nothing else.
#
# The pull request number does not exist, so nothing can be merged even if policy were
# missing, and the error text says which of the two happened:
#
#   refused   ->  "merge_pull_request is not defined"   (not a function in its sandbox)
#   allowed   ->  GitHub's own 404                      (reached GitHub and was answered)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEP="${1:?usage: try-merge.sh <agent-deployment> [pullNumber]}"
PR="${2:-99999}"
REPO="${DEMO_REPO:-tjorourke/kagent}"

python3 - "$REPO" "$PR" > /tmp/merge-params.json <<'PY'
import json, sys
repo, pr = sys.argv[1], int(sys.argv[2])
owner, name = repo.split("/")
# await, or the sandbox returns the pending promise and prints {} whether the call
# was allowed or not, which would prove nothing.
program = 'await merge_pull_request({owner: "%s", repo: "%s", pullNumber: %d})' % (owner, name, pr)
print(json.dumps({"name": "run_code", "arguments": {"code": program}}))
PY

echo "  as $DEP:  await merge_pull_request({owner: \"${REPO%/*}\", repo: \"${REPO#*/}\", pullNumber: $PR})"
"$HERE/mcp-from-pod.sh" "$DEP" tools/call /tmp/merge-params.json \
  | python3 -c '
import json, sys, re
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    print("    " + raw[:300]); raise SystemExit
body = d.get("result", {}).get("content", [{}])[0].get("text") or json.dumps(d.get("error", d))
# the sandbox returns {"error": "..."} inside the text payload, so unwrap one more level
try:
    inner = json.loads(body)
    body = inner.get("error") or inner.get("success") or body
except Exception:
    pass
body = re.sub(r"\s+", " ", json.dumps(body) if not isinstance(body, str) else body)
print("    " + body[:300])'

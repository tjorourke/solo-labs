#!/usr/bin/env bash
# rebuild-agent.sh — rebuild the agent image and get it ACTUALLY running.
#
# The trap this works around: the agent image is `localhost:5001/prtriage:latest`
# and kagent runs it with imagePullPolicy IfNotPresent. Push a new image on the
# same tag and a rollout restart will happily reuse the node's cached copy, so
# the agent keeps running the OLD prompts and you debug a change that was never
# deployed. So we drop the cached image from every node before restarting.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)/adk-python"
IMAGE="${IMAGE:-localhost:5001/prtriage:latest}"
K="kubectl --context kind-mesh1"

echo "== bake the approved skill into the agent's prompts =="
awk '/^---$/{c++;next} c>=2' "$HERE/../skill/release-report/SKILL.md" \
  | jq -Rs '[{name:"release-report", content:.}]' \
  > "$PROJECT/prtriage/prompts.json"

echo "== build + push =="
arctl build "$PROJECT" --push >/dev/null
arctl apply -f "$PROJECT/agent.yaml" >/dev/null

echo "== drop the stale cached image from the kind nodes =="
for node in $(kind get nodes --name mesh1); do
  docker exec "$node" crictl rmi "$IMAGE" >/dev/null 2>&1 || true
done

# On a first run the agent has not been deployed yet (that is the next step), so
# there is nothing to restart and nothing to verify. Only reload if it is running.
if ! $K -n kagent get deploy/prtriage >/dev/null 2>&1; then
  echo "✓ image built and pushed; the agent is not deployed yet, so deploy it next"
  exit 0
fi

echo "== restart and wait =="
"$HERE/reload-agent.sh" >/dev/null

POD="$($K -n kagent get pods -l app.kubernetes.io/name=prtriage -o name | head -1)"
if $K -n kagent exec "${POD#*/}" -- grep -q "today is not defined" /app/prtriage/prompts.json 2>/dev/null; then
  echo "✓ the running pod has the current skill"
else
  echo "✗ the running pod does NOT have the current skill - the image did not update"
  exit 1
fi

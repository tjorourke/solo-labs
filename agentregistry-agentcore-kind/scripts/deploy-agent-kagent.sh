#!/usr/bin/env bash
# deploy-agent-kagent.sh — deploy the agentdemo agent onto the kagent runtime with
# its model key sourced from the kagent-anthropic Secret (not hardcoded in the
# deploy). Deploys the agent, then wires ANTHROPIC_API_KEY into the kagent v1alpha2
# Agent CR from the Secret via env.valueFrom.secretKeyRef. Re-applies the wiring on
# every run, so call it wherever you'd `arctl apply` the agent.
#
#   ./scripts/deploy-agent-kagent.sh                       # default deploy file
#   ./scripts/deploy-agent-kagent.sh yaml/deploy-kagent.yaml
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="${LAB_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DEPLOY_FILE="${1:-$LAB_ROOT/yaml/deploy-kagent.yaml}"
AGENT_NAME="${AGENT_NAME:-agentdemo}"
MODEL_SECRET="${KAGENT_MODEL_SECRET:-kagent-anthropic}"
MODEL_SECRET_KEY="${KAGENT_MODEL_SECRET_KEY:-ANTHROPIC_API_KEY}"

step "Deploying agent '${AGENT_NAME}' via the registry (no key in the Deployment)"
arctl apply -f "$DEPLOY_FILE"

step "Waiting for the registry to create the kagent Agent CR"
for _ in $(seq 1 30); do
  kc -n kagent get agent "$AGENT_NAME" >/dev/null 2>&1 && break
  sleep 2
done
kc -n kagent get agent "$AGENT_NAME" >/dev/null 2>&1 \
  || die "kagent Agent '${AGENT_NAME}' never appeared — check: arctl get deployments"

step "Patching the Agent CR to read ${MODEL_SECRET_KEY} from Secret/${MODEL_SECRET} (no cleartext)"
kc -n kagent get agent "$AGENT_NAME" -o json \
| MODEL_SECRET="$MODEL_SECRET" MODEL_SECRET_KEY="$MODEL_SECRET_KEY" python3 -c '
import sys, json, os
a = json.load(sys.stdin)
d = a["spec"]["byo"]["deployment"]
name, key = os.environ["MODEL_SECRET"], os.environ["MODEL_SECRET_KEY"]
env = [e for e in d.get("env", []) if e.get("name") != key]
env.append({"name": key, "valueFrom": {"secretKeyRef": {"name": name, "key": key}}})
print(json.dumps({"spec": {"byo": {"deployment": {"env": env}}}}))
' > /tmp/agentdemo-secret-patch.json
kc -n kagent patch agent "$AGENT_NAME" --type=merge --patch-file /tmp/agentdemo-secret-patch.json

step "Waiting for the agent rollout"
kc -n kagent rollout status "deploy/${AGENT_NAME}" --timeout=180s

ok "Agent '${AGENT_NAME}' deployed — ${MODEL_SECRET_KEY} sourced from Secret/${MODEL_SECRET}, never cleartext"

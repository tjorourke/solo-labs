#!/usr/bin/env bash
# 04-harness.sh — create the OpenClaw AgentHarness, wait for Ready, record what kagent generated.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
mkdir -p "$CAPTURES"

step "AgentHarness ${NS}/${HARNESS} (backend openclaw, direct ModelConfig)"
kc apply -f "$YAML/20-openclaw-harness.yaml"
for _ in $(seq 1 30); do [[ "$(condition "agentharness/${HARNESS}" Accepted)" == True ]] && break; sleep 2; done
[[ "$(condition "agentharness/${HARNESS}" Accepted)" == True ]] || die "AgentHarness not Accepted: $(condition_msg "agentharness/${HARNESS}" Accepted)"
ok "Accepted"
# Ready means the ActorTemplate golden snapshot exists. First build is a few minutes.
for _ in $(seq 1 120); do [[ "$(condition "agentharness/${HARNESS}" Ready)" == True ]] && break; sleep 5; done
[[ "$(condition "agentharness/${HARNESS}" Ready)" == True ]] || die "AgentHarness not Ready: $(condition_msg "agentharness/${HARNESS}" Ready)"
ok "Ready: $(condition_msg "agentharness/${HARNESS}" Ready)"

step "what kagent generated"
kc -n "$NS" get agentharness "$HARNESS"
kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o custom-columns='ACTORTEMPLATE:.metadata.name,CLASS:.spec.sandboxClass,PHASE:.status.phase,GOLDEN:.status.goldenActorID'
kc -n "$NS" get agentharness "$HARNESS" -o yaml > "$CAPTURES/harness-status.yaml"
kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o yaml > "$CAPTURES/actor-template.yaml"
image=$(kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o jsonpath='{.spec.containers[0].image}')
log "workload image: ${image}"
# Decode the openclaw.json kagent wrote into the actor startup script.
kc -n "$NS" get actortemplates.ate.dev "$HARNESS" -o jsonpath='{.spec.containers[0].command[2]}' \
  | grep -o "echo '[^']*' | base64 -d" | head -1 | sed "s/echo '//; s/' | base64 -d//" | base64 -d \
  | python3 -m json.tool > "$CAPTURES/openclaw-json-generated.json"
log "generated openclaw.json: $CAPTURES/openclaw-json-generated.json"
# The OpenClaw version inside kagent's backend image, read from the image itself.
if docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null 2>&1; then
  docker run --rm --entrypoint openclaw "$image" --version | tee "$CAPTURES/backend-openclaw-version.txt"
fi
ok "harness is ready; chat with: ./scripts/ask.sh \"...\""

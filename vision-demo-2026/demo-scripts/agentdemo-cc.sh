#!/usr/bin/env bash
# agentdemo-cc.sh — stand up the coding-harness agent next to the ADK one, and talk to
# both. Runs on the Part 5 cluster because a kagent AgentHarness REQUIRES Agent
# Substrate: its spec.substrate is mandatory, and the harness runs as a gVisor actor on
# a WorkerPool rather than as a pod of its own.
#
#   ./demo-scripts/agentdemo-cc.sh up      # deploy agentdemo (ADK) + agentdemo-cc (harness)
#   ./demo-scripts/agentdemo-cc.sh ask     # prompt both and print their answers
#   ./demo-scripts/agentdemo-cc.sh down    # remove both
#
# The two are deliberately the same dice agent through different doors:
#   agentdemo     type: BYO         an image you built with arctl, one pod
#   agentdemo-cc  AgentHarness      backend openclaw (the claude-code family), one actor
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${CTX:-kind-substrate}"
NS="${KAGENT_NS:-kagent}"
PORT="${ACP_PORT:-19110}"
# The controller has no acp-sandbox image baked in unless it was built with one, so the
# harness must name a DIGEST-pinned workload image or it fails with
# "image digest is not set at link time".
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/kagent-dev/kagent/acp-sandbox-openclaw@sha256:9a0a2ab8e3e74ffe17db44ff99feb1ef22ea77867557c6c9cbe9dec53d5b2bfb}"
AGENT_IMAGE="${AGENT_IMAGE:-localhost:5001/agentdemo:latest}"

kc() { kubectl --context "$CTX" "$@"; }
pf_up() { kc -n "$NS" port-forward svc/kagent-controller "$PORT":8083 >/tmp/agentdemo-cc-pf.log 2>&1 & sleep 5; }
pf_down() { pkill -f "port-forward.*${PORT}:8083" 2>/dev/null || true; }

case "${1:-up}" in
down)
  kc -n "$NS" delete agentharness agentdemo-cc --ignore-not-found
  kc -n "$NS" delete agent agentdemo --ignore-not-found
  echo "✔ both agents removed"; exit 0 ;;

up)
  echo "→ agentdemo: the ADK image you built with arctl, as an ordinary pod"
  kc apply -f - >/dev/null <<YAML
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: { name: agentdemo, namespace: ${NS} }
spec:
  type: BYO
  description: The arctl-built ADK dice agent.
  byo:
    deployment:
      image: ${AGENT_IMAGE}
      env:
      - { name: MODEL_PROVIDER, value: anthropic }
      - { name: MODEL_NAME, value: claude-haiku-4-5 }
      - name: ANTHROPIC_API_KEY
        valueFrom:
          secretKeyRef: { name: kagent-anthropic, key: ANTHROPIC_API_KEY }
YAML
  echo "→ agentdemo-cc: the same job under a coding harness, as a gVisor actor"
  kc apply -f - >/dev/null <<YAML
apiVersion: kagent.dev/v1alpha2
kind: AgentHarness
metadata: { name: agentdemo-cc, namespace: ${NS} }
spec:
  description: Dice agent running under a coding harness on Agent Substrate.
  backend: openclaw
  modelConfigRef: default-model-config
  substrate:
    workerPoolRef: { name: kagent-default }
    workloadImage: "${OPENCLAW_IMAGE}"
YAML
  for _ in $(seq 1 60); do kc -n "$NS" get deploy/agentdemo >/dev/null 2>&1 && break; sleep 2; done
  kc -n "$NS" rollout status deploy/agentdemo --timeout=300s >/dev/null
  for _ in $(seq 1 60); do
    [ "$(kc -n "$NS" get agentharness agentdemo-cc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
    sleep 5
  done
  echo
  kc -n "$NS" get agentharness agentdemo-cc \
    -o custom-columns='HARNESS:.metadata.name,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status,READY:.status.conditions[?(@.type=="Ready")].status,ACTOR:.status.conditions[?(@.type=="ActorReady")].status'
  kc -n "$NS" get actortemplate -o custom-columns='ACTORTEMPLATE:.metadata.name,CLASS:.spec.sandboxClass' 2>/dev/null | grep -E "ACTORTEMPLATE|agentdemo-cc" || true
  echo
  echo "✔ both up. Ask them:  $0 ask"
  echo "  kagent UI lists agentdemo as an Agent and agentdemo-cc as an AgentHarness."
  exit 0 ;;

ask)
  pf_up
  trap pf_down EXIT
  PROMPT_ADK="${2:-Roll a 20-sided die and tell me whether the result is prime.}"
  PROMPT_CC="${3:-In one sentence: what are you, and what sandbox are you running in?}"

  echo "== agentdemo (ADK image, A2A) =="
  sid=$(curl -s -m 15 -X POST "http://localhost:${PORT}/api/sessions" -H 'content-type: application/json' \
        -d '{"agent_ref":"kagent/agentdemo","name":"dice"}' \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))')
  req=$(python3 -c "import json,sys;print(json.dumps({'jsonrpc':'2.0','id':'1','method':'message/send','params':{'message':{'role':'user','parts':[{'kind':'text','text':sys.argv[1]}],'messageId':'m1','contextId':sys.argv[2]}}}))" "$PROMPT_ADK" "$sid")
  curl -s --max-time 120 -X POST "http://localhost:${PORT}/api/a2a/kagent/agentdemo/" \
       -H 'content-type: application/json' -d "$req" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);a=d.get("result",{}).get("artifacts");print("  "+(a[0]["parts"][0]["text"].strip() if a else "no answer"))'

  echo
  echo "== agentdemo-cc (coding harness, ACP over a websocket) =="
  # A harness speaks the Agent Client Protocol, not A2A: initialize, session/new, then
  # session/prompt, over a websocket the controller exposes per kagent session.
  csid=$(curl -s -m 15 -X POST "http://localhost:${PORT}/api/sessions" -H 'content-type: application/json' \
         -d '{"agent_ref":"kagent/agentdemo-cc","name":"harness"}' \
         | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))')
  ACP_PORT="$PORT" python3 "$SCRIPT_DIR/acp-chat.py" "/api/agentharnesses/kagent/agentdemo-cc/acp/${csid}" "$PROMPT_CC"
  exit 0 ;;
*)
  echo "usage: $0 [up|ask|down]"; exit 1 ;;
esac

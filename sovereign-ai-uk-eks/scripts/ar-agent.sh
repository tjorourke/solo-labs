#!/usr/bin/env bash
# Register an agent in agentregistry and deploy it onto kagent, from the registry.
#
# This is the governance spine of the lab: AR is the one place an agent is described, and
# the one place it is deployed from. A developer does not `kubectl apply` an Agent; they
# register it here and deploy it here, and the cluster refuses anything that skips that
# path (yaml/42-agent-admission.yaml). The agent this deploys reaches the in-region model
# only through the gateway, so it has no route to any external LLM.
#
#   ./scripts/ar-agent.sh token     print an arctl bearer token (carol, AR superuser)
#   ./scripts/ar-agent.sh register  arctl apply the Agent (catalogue entry)
#   ./scripts/ar-agent.sh deploy    apply the Runtime + Deployment (runs it on kagent)
#   ./scripts/ar-agent.sh verify    show the kagent Agent CR + pod + who authored the CR
#   ./scripts/ar-agent.sh refuse    prove a hand-applied Agent is refused at admission
#   ./scripts/ar-agent.sh all        register -> deploy -> verify
#
# The agent image is built once from the arctl scaffold (arctl init agent, then create_model
# pointed at the gateway) and pushed to a public registry the cluster can pull anonymously.
# Rebuild only when the agent code changes.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2; CLUSTER=uk-sovereign-ai
AR_NS=agentregistry; KC_NS=keycloak; REALM=sovereign
ARCTL="${ARCTL:-$HOME/.arctl/bin/arctl}"
# a realm user in the 'admin' group; AR's superuserRole is 'admin' (see agentregistry.sh).
AR_USER="${AR_USER:-carol}"; AR_PASS="${AR_PASS:-carol}"
IMAGE="${AGENT_IMAGE:-public.ecr.aws/j8r2p7b6/sovereign-analyst:v1}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }

# Port-forward keycloak + the AR server for the life of one command, then tear down.
PF_PIDS=()
pf_up() {
  kc -n "$KC_NS" port-forward svc/keycloak 8085:80 >/tmp/pf-kc.log 2>&1 & PF_PIDS+=($!)
  kc -n "$AR_NS" port-forward svc/agentregistry-enterprise-server 12121:12121 >/tmp/pf-ar.log 2>&1 & PF_PIDS+=($!)
  sleep 6
}
pf_down() { for p in "${PF_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; PF_PIDS=(); }
trap pf_down EXIT

token() {
  curl -s -X POST "http://localhost:8085/realms/${REALM}/protocol/openid-connect/token" \
    -d "client_id=ar-ui" -d "username=${AR_USER}" -d "password=${AR_PASS}" \
    -d 'grant_type=password' -d 'scope=openid' \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))'
}

register() {
  export ARCTL_API_BASE_URL=http://localhost:12121 ARCTL_API_TOKEN="$(token)"
  "$ARCTL" apply -f - <<'AGENT'
apiVersion: ar.dev/v1alpha1
kind: Agent
metadata:
  name: sovereignanalyst
spec:
  description: Sovereign analyst — reaches the in-region Mistral only through the gateway
  modelName: mistral-small-3.2-24b
  modelProvider: openai
  source:
    image: public.ecr.aws/j8r2p7b6/sovereign-analyst:v1
framework: adk
language: python
modelProvider: openai
modelName: mistral-small-3.2-24b
AGENT
  "$ARCTL" get agents
}

deploy() {
  export ARCTL_API_BASE_URL=http://localhost:12121 ARCTL_API_TOKEN="$(token)"
  # The Runtime is the kagent target: AR calls kagent's API with an OIDC token minted for
  # the kagent-enterprise client, and the kagent controller writes the Agent CR. The
  # Deployment binds the registered agent to that runtime and passes the model wiring as
  # env, so the running agent's only model endpoint is the in-cluster gateway.
  "$ARCTL" apply -f - <<'DEPLOY'
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: sovereign-kagent
spec:
  type: Kagent
  config:
    kagentUrl: "http://kagent-controller.kagent.svc.cluster.local:8083"
    namespace: "kagent"
    auth:
      oidc:
        issuer: "http://keycloak.keycloak.svc.cluster.local/realms/sovereign"
        clientId: "kagent-enterprise"
        insecureSkipVerify: true
        clientSecretRef:
          name: agentregistry-enterprise-kagent-outbound-oidc
          key: KAGENT_OUTBOUND_OIDC_CLIENT_SECRET
---
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: sovereignanalyst
spec:
  targetRef:
    kind: Agent
    name: sovereignanalyst
    tag: "latest"
  runtimeRef:
    kind: Runtime
    name: sovereign-kagent
  env:
    SOVEREIGN_MODEL_BASE_URL: "http://sovereign-gateway.agentgateway-system.svc.cluster.local/v1"
    SOVEREIGN_MODEL_NAME: "mistral-small-3.2-24b"
DEPLOY
}

verify() {
  echo "== kagent Agent CR (deployed from AR)"
  kc -n kagent get agents.kagent.dev sovereignanalyst 2>/dev/null
  echo "== authored by (managedFields manager — 'app' is the kagent controller, not a human)"
  kc -n kagent get agents.kagent.dev sovereignanalyst -o jsonpath='{.metadata.managedFields[0].manager}{"\n"}' 2>/dev/null
  echo "== pod"
  kc -n kagent get pods --no-headers 2>/dev/null | grep '^sovereignanalyst-'
}

refuse() {
  echo "== hand-applying an Agent that never passed through AR (must be DENIED):"
  kc apply -f - 2>&1 <<'ROGUE' | tail -3
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: rogue-sideloaded
  namespace: kagent
spec:
  description: an agent nobody registered
  type: BYO
  byo:
    deployment:
      image: public.ecr.aws/docker/library/busybox:1.36
ROGUE
}

case "${1:-all}" in
  token)    pf_up; token ;;
  register) pf_up; register ;;
  deploy)   pf_up; deploy ;;
  verify)   verify ;;
  refuse)   refuse ;;
  all)      pf_up; register; deploy; sleep 20; verify ;;
  *) echo "usage: $0 {token|register|deploy|verify|refuse|all}"; exit 1 ;;
esac

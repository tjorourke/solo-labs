#!/usr/bin/env bash
# How to connect to the running cluster: kubeconfig, the /etc/hosts line for the consoles,
# the console URLs and logins, and how to reach the model. deploy-all.sh prints this at the
# end of a run; run it any time to print it again.
#
#   ./scripts/access.sh              print the connectivity details
#   ./scripts/access.sh kubeconfig   write a standalone kubeconfig to ./uk-sovereign-ai.kubeconfig
#   ./scripts/access.sh hosts        print just the /etc/hosts line
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to your AWS SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kc() { command kubectl --context "$CTX" "$@"; }

HOSTS="age.sovereign.local kagent.sovereign.local registry.sovereign.local keycloak.sovereign.local"
nlb_ip() {
  local nlb; nlb="$(kc -n agentgateway-system get svc sovereign-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  [ -n "$nlb" ] && dig +short "$nlb" 2>/dev/null | grep -E '^[0-9]' | head -1
}

case "${1:-show}" in
  kubeconfig)
    f="$HERE/uk-sovereign-ai.kubeconfig"
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$f" >/dev/null
    echo "wrote $f"
    echo "use it with:  KUBECONFIG=$f kubectl get nodes"
    ;;
  hosts)
    echo "$(nlb_ip)  ${HOSTS}"
    ;;
  show|*)
    IP="$(nlb_ip)"
    cat <<EOF

════════ connect to ${CLUSTER} (${REGION}) ════════

1) kubectl — point it at the cluster:
     aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER}
     kubectl config use-context ${CTX}
   or a standalone kubeconfig file:
     ./scripts/access.sh kubeconfig      # writes ./uk-sovereign-ai.kubeconfig

2) /etc/hosts — so the consoles resolve to the gateway (run once):
     echo "${IP:-<gateway-ip>}  ${HOSTS}" | sudo tee -a /etc/hosts
   (the gateway is an NLB; its IP can change if the gateway is recreated — re-run
    './scripts/access.sh hosts' to get the current line)

3) consoles — in a browser. Log in with a realm user; password = the username.
     carol / carol  (admin)   ·   alice / alice  (platform)   ·   bob / bob  (research)
     agentgateway    https://age.sovereign.local/age
     kagent          https://kagent.sovereign.local
     agentregistry   https://registry.sovereign.local
     keycloak        https://keycloak.sovereign.local        (Keycloak admin: admin / admin)

4) ask the model — directly over a port-forward, no token needed:
     kubectl -n models port-forward svc/vllm 8000:8000
     curl localhost:8000/v1/chat/completions -H 'content-type: application/json' \\
       -d '{"model":"mistral-small-3.2-24b","messages":[{"role":"user","content":"what region are you in?"}]}'
   or through the gateway, with a real Keycloak token (the governed path):
     ./scripts/ask.sh "what region are you in?"

5) stop the GPU meter (\$5.84/hr) when you finish:
     ./scripts/gpu.sh down

EOF
    ;;
esac

#!/usr/bin/env bash
# quick.sh — orchestrate the lab.
#   ./scripts/quick.sh up         # cluster, Keycloak, kagent-enterprise, management UI, MCP, agent
#   ./scripts/quick.sh status     # what is running
#   ./scripts/quick.sh teardown   # delete the kind cluster
#
# This lab is written as a read-along walkthrough in index.html; this driver runs
# sections 1 to 3 and 6, which are the file-backed parts, so labs-e2e.sh can prove
# the stack still stands up. Left out on purpose: section 4 (BYO/ADK) needs a
# local image build, section 5 (tool governance) is an optional agentgateway
# add-on, and section 7 (SandboxAgent) is Beta.
#
# Versions come from versions.env rather than the literals in the page, so the
# lab is exercised against the current product matrix.
set -Euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

# shellcheck disable=SC1091
[ -f "$REPO_ROOT/versions.env" ] && source "$REPO_ROOT/versions.env"
[ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && source "$SECRETS_FILE"

CLUSTER="${CLUSTER:-kagent-poc}"
CTX="kind-${CLUSTER}"
KAGENT_VER="${KAGENT_ENT_VERSION:-0.5.6}"
MGMT_VER="${SOLO_ENT_MGMT_VERSION:-0.5.6}"
ISSUER="http://keycloak.localtest.me:18080/realms/solo"

step() { printf '\n\033[1;36m══> %s\033[0m\n' "$*" >&2; }
k()    { kubectl --context "$CTX" "$@"; }

up() {
  : "${SOLO_LICENSE_KEY:?set SOLO_LICENSE_KEY (or point SECRETS_FILE at secrets-envs.sh)}"
  : "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"

  step "kind cluster '$CLUSTER'"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"

  step "Keycloak"
  k create namespace keycloak --dry-run=client -o yaml | k apply -f -
  k -n keycloak create configmap keycloak-realm-import \
    --from-file=realm.json="$ROOT/yaml/keycloak/realm.json" --dry-run=client -o yaml | k apply -f -
  k -n keycloak apply -f "$ROOT/yaml/keycloak/keycloak.yaml"
  k -n keycloak rollout status statefulset/keycloak --timeout=600s

  step "CoreDNS rewrite so the controller resolves the issuer in-cluster"
  k -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' \
    | awk '/^    ready$/{print; print "    rewrite name keycloak.localtest.me keycloak.keycloak.svc.cluster.local"; next} 1' > /tmp/Corefile.$$
  k -n kube-system create cm coredns --from-file=Corefile=/tmp/Corefile.$$ --dry-run=client -o yaml | k apply -f -
  rm -f /tmp/Corefile.$$
  k -n kube-system rollout restart deploy/coredns
  k -n kube-system rollout status deploy/coredns --timeout=120s

  step "kagent namespace, OBO signing key and OIDC secrets"
  k create namespace kagent --dry-run=client -o yaml | k apply -f -
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/kagent-obo.$$.pem 2>/dev/null
  k -n kagent create secret generic jwt --from-file=jwt=/tmp/kagent-obo.$$.pem --dry-run=client -o yaml | k apply -f -
  rm -f /tmp/kagent-obo.$$.pem
  k -n kagent create secret generic kagent-enterprise-oidc-secret --from-literal=clientSecret=public-client-no-secret --dry-run=client -o yaml | k apply -f -
  k -n kagent create secret generic ui-backend-oidc-secret --from-literal=clientSecret=kagent-backend-secret --dry-run=client -o yaml | k apply -f -

  step "Solo Enterprise for kagent ($KAGENT_VER)"
  helm --kube-context "$CTX" upgrade -i kagent-crds \
    oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds \
    -n kagent --version "$KAGENT_VER" --wait
  helm --kube-context "$CTX" upgrade -i kagent \
    oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise \
    -n kagent --version "$KAGENT_VER" \
    --set global.licensing.licenseKey="$SOLO_LICENSE_KEY" \
    --set providers.default=anthropic \
    --set providers.anthropic.apiKey="$ANTHROPIC_API_KEY" \
    --set oidc.issuer="$ISSUER" \
    --set oidc.clientId=kagent \
    --set oidc.skipOBO=false \
    --set kagent-tools.enabled=true \
    --set otel.tracing.enabled=true \
    --set otel.tracing.exporter.otlp.endpoint="http://solo-enterprise-telemetry-collector.kagent:4317" \
    --set-json 'controller.envFrom=[{"configMapRef":{"name":"kagent-enterprise-config"}}]' \
    --set-json 'rbac.roleMapping={"roleMapper":"claims.groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"field-fte":"global.Admin","field-trial":"global.Reader","field-admin":"global.Admin"}}' \
    --wait --timeout 12m

  step "Solo Enterprise management UI ($MGMT_VER)"
  helm --kube-context "$CTX" upgrade -i management \
    oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
    -n kagent --version "$MGMT_VER" \
    --set cluster="$CLUSTER" \
    --set products.kagent.enabled=true \
    --set products.kagent.namespace=kagent \
    --set oidc.issuer="$ISSUER" \
    --set-json 'rbac.roleMapping={"roleMapper":"has(claims.groups) ? claims.groups.transformList(i, v, v in rolesMap, rolesMap[v]) : []","roleMappings":{"field-fte":"global.Admin","field-admin":"global.Admin","field-trial":"global.Reader"}}' \
    --set-string licensing.licenseKey="$SOLO_LICENSE_KEY"
  k -n kagent rollout status deploy/solo-enterprise-ui --timeout=600s

  step "MCP tool server and the declarative agent"
  k -n kagent create secret generic anthropic-key --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" --dry-run=client -o yaml | k apply -f -
  k apply -f "$ROOT/yaml/mcp/mcpserver.yaml"
  k apply -f "$ROOT/yaml/agent/declarative-agent.yaml"

  step "Up. BYO/ADK, tool governance and the Sandbox sections are not run here."
}

case "${1:-up}" in
  up)       up ;;
  status)
    kind get clusters 2>/dev/null | sed 's/^/  /' >&2 || true
    k -n kagent get agents,mcpservers,pods 2>/dev/null | sed 's/^/  /' >&2 || true
    ;;
  teardown) kind delete cluster --name "$CLUSTER" ;;
  *) echo "usage: quick.sh [up|status|teardown]" >&2; exit 2 ;;
esac

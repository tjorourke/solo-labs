#!/usr/bin/env bash
# 24-agentregistry.sh — AgentRegistry Enterprise in-cluster (server + bundled
# Postgres + ClickHouse + telemetry collector). Installed WITH its AWS source
# identity from the start: the tofu-created ar-control-plane IAM user's static
# key via the chart's aws.* values (Secret + envFrom into the server pod).
# The server assumes each Runtime's AgentRegistryAccess role from these creds;
# they never expire, unlike the SSO-derived creds the older lab injected.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets
load_tofu_env
ensure_gar_auth "$GAR_HOST"
[[ -n "${AR_BACKEND_SECRET:-}" ]] || die "AR_BACKEND_SECRET not set — run ./scripts/21-keycloak.sh first"

step "Installing AgentRegistry ${AR_VERSION} in ${AR_NS}"
helm_install_with_progress agentregistry "$AR_CHART" "$AR_NS" \
  --version "$AR_VERSION" \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set oidc.clientId="${AR_BACKEND_CLIENT}" \
  --set oidc.clientSecret="${AR_BACKEND_SECRET}" \
  --set oidc.publicClientId="${AR_UI_CLIENT}" \
  --set oidc.roleClaim=Groups \
  --set oidc.superuserRole="${RBAC_SUPERUSER_ROLE}" \
  --set database.postgres.type=bundled \
  --set aws.enabled=true \
  --set aws.accessKeyId="${AR_AWS_ACCESS_KEY_ID}" \
  --set aws.secretAccessKey="${AR_AWS_SECRET_ACCESS_KEY}" \
  --set aws.region="${PORTFOLIO_A_REGION}" \
  --set config.enabledRuntimes='{agentcore,virtual}' \
  --set licensing.createSecret=true \
  --set licensing.secretName=enterprise-agentregistry-license \
  --set licensing.licenseKey="${AGENTREGISTRY_LICENSE_KEY:-${AGENTGATEWAY_LICENSE_KEY}}"
ok "AgentRegistry chart applied"

step "Bridging the Keycloak issuer into the registry server pod, then waiting"
for _ in $(seq 1 30); do kc -n "$AR_NS" get deploy "$AR_SERVER_SVC" >/dev/null 2>&1 && break; sleep 2; done
bridge_keycloak_hostalias "$AR_SERVER_SVC" "$AR_NS" \
  && ok "hostAlias ${KEYCLOAK_HOST} -> Keycloak ClusterIP added"
kc -n "$AR_NS" rollout status deploy/"$AR_SERVER_SVC" --timeout=300s >/dev/null 2>&1 \
  && ok "registry server Ready" || warn "registry server not Ready in 5m — check: kc -n $AR_NS get pods"

step "arctl login"
arctl_login && ok "arctl logged in as ${AS_USER} (${ARCTL_API_BASE_URL})"
echo "  Next: ./scripts/30-runtimes.sh" >&2

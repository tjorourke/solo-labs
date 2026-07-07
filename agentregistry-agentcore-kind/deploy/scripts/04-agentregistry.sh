#!/usr/bin/env bash
# 04-agentregistry.sh — install Solo Enterprise for AgentRegistry IN THE CLUSTER
# (v2026.6.1), the way customers run it. Replaces the old local Docker `arctl
# daemon`. The chart deploys the registry server + a bundled PostgreSQL + ClickHouse
# + an OTel telemetry collector into agentregistry-system. The server is secured by
# the agentregistry Keycloak realm (ar-backend confidential client + ar-ui public
# client); group `admins` -> registry superuser.
#
# The server does OIDC discovery against the gateway issuer (keycloak.localtest.me)
# at startup, so — like the kagent controller — it gets a hostAlias to Keycloak's
# ClusterIP. AWS creds for the Bedrock AgentCore runtime are added later, by the
# AgentCore connect step (they're short-lived SSO creds, so we don't bake them in
# at install time).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets
ensure_gar_auth "$GAR_HOST"
[[ -n "${AR_BACKEND_SECRET:-}" ]] || die "AR_BACKEND_SECRET not set — run ./scripts/02-keycloak.sh first"
[[ -n "${KAGENT_BACKEND_SECRET:-}" ]] || die "KAGENT_BACKEND_SECRET not set — run ./scripts/02-keycloak.sh first"

step "Installing AgentRegistry ${AR_VERSION} in ${AR_NS} (server + Postgres + ClickHouse + telemetry)"
# No --wait: the server does OIDC discovery against keycloak.localtest.me, which a
# pod can't resolve until the hostAlias is added (next step). superuserRole=admins
# + roleClaim=Groups match the realm's group-membership claim. The server Service is
# left ClusterIP; the agentgateway ingress (06-gateway.sh) exposes it at AR_HOST.
helm_install_with_progress agentregistry "$AR_CHART" "$AR_NS" \
  --version "$AR_VERSION" \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set oidc.clientId="${AR_BACKEND_CLIENT}" \
  --set oidc.clientSecret="${AR_BACKEND_SECRET}" \
  --set oidc.publicClientId="${AR_UI_CLIENT}" \
  --set oidc.roleClaim=Groups \
  --set oidc.superuserRole="${RBAC_SUPERUSER_ROLE}" \
  --set kagent.outboundAuth.oidc.clientId="${KAGENT_BACKEND_CLIENT}" \
  --set kagent.outboundAuth.oidc.clientSecret="${KAGENT_BACKEND_SECRET}" \
  --set database.postgres.type=bundled
ok "AgentRegistry chart applied"
# kagent.outboundAuth.oidc (above): when the registry deploys to the kagent runtime
# it mints a CLIENT-CREDENTIALS token to call the kagent controller. It defaults to
# oidc.clientId (ar-backend), which is a pure validator (no service account) AND
# carries aud=ar-backend — so kagent rejects it (oauth2 "unauthorized_client"). We
# point it at kagent-backend, which 02-keycloak makes a service-account client whose
# token carries aud=kagent-backend + Groups=[admins] (-> kagent global.Admin via the
# role mapper), so the deploy's "create tool server" / "create agent" calls authorize.

step "Bridging the Keycloak issuer into the registry server pod, then waiting"
for _ in $(seq 1 30); do kc -n "$AR_NS" get deploy "$AR_SERVER_SVC" >/dev/null 2>&1 && break; sleep 2; done
bridge_keycloak_hostalias "$AR_SERVER_SVC" "$AR_NS" \
  && ok "hostAlias ${KEYCLOAK_HOST} -> Keycloak ClusterIP added to ${AR_SERVER_SVC}"
kc -n "$AR_NS" rollout status deploy/"$AR_SERVER_SVC" --timeout=300s >/dev/null 2>&1 \
  && ok "registry server Ready" || warn "registry server not Ready in 5m — check: kc -n $AR_NS get pods"

step "AgentRegistry installed (in-cluster)"
echo "  UI/API: http://${AR_HOST} (once the gateway is up); arctl -> ${ARCTL_API_BASE_URL}" >&2
echo "  Next: ./scripts/05-waypoint.sh" >&2

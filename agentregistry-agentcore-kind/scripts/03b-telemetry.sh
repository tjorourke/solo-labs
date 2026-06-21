#!/usr/bin/env bash
# 03b-telemetry.sh — install the Solo Enterprise management chart: ClickHouse +
# the OTel telemetry collectors + the Solo Enterprise UI (kagent.localtest.me).
# This is where kagent TRACING / Agents / Access Policies live. Agents export OTLP
# -> the telemetry collector -> ClickHouse (platformdb.otel_traces_json), and the
# Enterprise UI's Tracing tab reads it back.
#
# OIDC: the UI logs in via the agentregistry realm. Frontend uses the public
# kagent-ui client (authcode+PKCE), backend uses the confidential kagent-backend
# client (its secret, scraped by 02-keycloak.sh). The UI backend does OIDC
# discovery against the gateway issuer (keycloak.localtest.me), reachable
# in-cluster via a hostAlias.
#
# Skip with SKIP_TELEMETRY=true (the rest of the demo works; only Tracing needs it).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets
ensure_gar_auth "$GAR_HOST"

if [[ "${SKIP_TELEMETRY:-false}" == "true" ]]; then
  log "SKIP_TELEMETRY=true — skipping ClickHouse/telemetry (no Tracing/Enterprise UI)"; exit 0
fi

step "OIDC client secret for the Enterprise UI backend (kagent-backend)"
[[ -n "${KAGENT_BACKEND_SECRET:-}" ]] || die "KAGENT_BACKEND_SECRET not set — run ./scripts/02-keycloak.sh first"
kc create namespace "$SOLO_MGMT_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$SOLO_MGMT_NS" create secret generic ui-backend-oidc-secret \
  --from-literal=clientSecret="${KAGENT_BACKEND_SECRET}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "ui-backend-oidc-secret ready"

step "Installing the Solo Enterprise management chart ${SOLO_ENT_MGMT_VERSION} (ClickHouse + telemetry + UI)"
# No --wait: setting oidc.issuer makes the UI backend do OIDC discovery against
# keycloak.localtest.me, which a pod can't resolve until the hostAlias is added
# (next step). So: install, add the alias, THEN wait.
helm --kube-context "$CTX" upgrade --install solo-mgmt \
  "oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management" \
  --namespace "$SOLO_MGMT_NS" --version "$SOLO_ENT_MGMT_VERSION" \
  --set cluster="$CLUSTER_NAME" \
  --set products.kagent.enabled=true \
  --set products.kagent.namespace=kagent \
  --set products.agentgateway.namespace="$GW_NS" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY:-$KAGENT_ENT_LICENSE_KEY}" \
  --set clickhouse.persistentVolume.enabled=false \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set ui.frontend.oidc.clientId="${KAGENT_UI_CLIENT}" \
  --set ui.backend.oidc.clientId="${KAGENT_BACKEND_CLIENT}" \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  --timeout 10m >/dev/null
ok "management chart applied (ClickHouse + telemetry + Enterprise UI in $SOLO_MGMT_NS)"

step "Bridging the Keycloak issuer into the Enterprise UI pod, then waiting for readiness"
for _ in $(seq 1 30); do kc -n "$SOLO_MGMT_NS" get deploy solo-enterprise-ui >/dev/null 2>&1 && break; sleep 2; done
bridge_keycloak_hostalias solo-enterprise-ui "$SOLO_MGMT_NS" \
  && ok "hostAlias ${KEYCLOAK_HOST} -> Keycloak ClusterIP added to solo-enterprise-ui"
kc -n "$SOLO_MGMT_NS" rollout status statefulset/solo-mgmt-clickhouse-shard0 --timeout=300s >/dev/null 2>&1 || true
kc -n "$SOLO_MGMT_NS" rollout status deploy/solo-enterprise-ui --timeout=300s >/dev/null 2>&1 \
  && ok "Enterprise UI ready (Keycloak SSO)" || warn "Enterprise UI not Ready in 5m — check: kc -n $SOLO_MGMT_NS get pods"

step "Telemetry + Enterprise UI ready"
echo "  Tracing console: http://${KAGENT_UI_HOST} (./scripts/open-consoles.sh; login admin-user/password)" >&2

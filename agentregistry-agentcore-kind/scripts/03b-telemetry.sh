#!/usr/bin/env bash
# 03b-telemetry.sh — install the Solo Enterprise management chart: ClickHouse +
# the OTel telemetry collectors + the Solo Enterprise UI. This is where TRACING
# lives. Agents export OTLP -> the telemetry collector -> ClickHouse
# (platformdb.otel_traces_json), and the Enterprise UI's Tracing tab reads it
# back. The kagent controller (03-kagent.sh, otel.tracing.enabled) stamps the
# collector endpoint into every agent it deploys.
#
# The Enterprise UI logs in via the SAME Keycloak as the rest of the lab (alice /
# alice) instead of its built-in autoauth IdP. Autoauth hands the browser an
# in-cluster issuer URL (…svc.cluster.local:5556) it can't resolve; pointing
# oidc.issuer at keycloak.localtest.me:18080 (browser-reachable via public DNS,
# in-cluster-reachable via a hostAlias) makes login work with no /etc/hosts.
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

step "OIDC client secret for the Enterprise UI backend (validates Keycloak tokens)"
# The UI's frontend + backend both use the public `kagent` client; alice's token
# already carries aud=kagent and the groups claim. The secretRef the chart wants
# is just a placeholder for a public client.
kc create namespace "$SOLO_MGMT_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$SOLO_MGMT_NS" create secret generic ui-backend-oidc-secret \
  --from-literal=clientSecret="public-client-no-secret" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "ui-backend-oidc-secret ready"

step "Installing the Solo Enterprise management chart ${SOLO_ENT_MGMT_VERSION} (ClickHouse + telemetry + UI)"
# NB: no --wait here. Setting oidc.issuer disables the built-in autoauth IdP, so
# the UI backend does OIDC discovery against keycloak.localtest.me — which a pod
# can't resolve until we add a hostAlias to Keycloak's ClusterIP (next step). With
# --wait, helm would block on a UI that CrashLoops until the alias exists, a
# chicken-and-egg deadlock. So: install, add the alias, THEN wait for readiness.
helm --kube-context "$CTX" upgrade --install solo-mgmt \
  "oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management" \
  --namespace "$SOLO_MGMT_NS" --version "$SOLO_ENT_MGMT_VERSION" \
  --set cluster="$CLUSTER_NAME" \
  --set products.kagent.enabled=true \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY:-$KAGENT_ENT_LICENSE_KEY}" \
  --set clickhouse.persistentVolume.enabled=false \
  --set oidc.issuer="${KEYCLOAK_ISSUER}" \
  --set ui.frontend.oidc.clientId="${KEYCLOAK_CLIENT}" \
  --set ui.backend.oidc.clientId="${KEYCLOAK_CLIENT}" \
  --set-json 'rbac.roleMapping={"roleMapper":"claims.groups.transformList(i, v, v in rolesMap, rolesMap[v])","roleMappings":{"field-fte":"global.Admin","field-trial":"global.Reader","field-admin":"global.Admin","admins":"global.Admin","readers":"global.Reader","writers":"global.Writer"}}' \
  --timeout 10m >/dev/null
ok "management chart applied (ClickHouse + telemetry + Enterprise UI in $SOLO_MGMT_NS)"

step "Bridging the Keycloak issuer into the Enterprise UI pod, then waiting for readiness"
# hostAlias so the UI backend resolves the browser-style issuer in-cluster (same
# bridge 03-kagent uses for the controller). Wait for the Deployment to exist
# first (helm without --wait returns as soon as objects are applied).
for _ in $(seq 1 30); do kc -n "$SOLO_MGMT_NS" get deploy solo-enterprise-ui >/dev/null 2>&1 && break; sleep 2; done
KCIP="$(kc -n "$KEYCLOAK_NS" get svc keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
if [[ -n "$KCIP" ]]; then
  kc -n "$SOLO_MGMT_NS" patch deploy solo-enterprise-ui --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$KCIP\",\"hostnames\":[\"${KEYCLOAK_OIDC_HOST%%:*}\"]}]}]" >/dev/null 2>&1 \
  || kc -n "$SOLO_MGMT_NS" patch deploy solo-enterprise-ui --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$KCIP\",\"hostnames\":[\"${KEYCLOAK_OIDC_HOST%%:*}\"]}]}]" >/dev/null 2>&1 || true
  ok "hostAlias ${KEYCLOAK_OIDC_HOST%%:*} -> ${KCIP} added to solo-enterprise-ui"
else
  warn "Keycloak ClusterIP not found; Enterprise UI login may fail OIDC discovery"
fi
kc -n "$SOLO_MGMT_NS" rollout status statefulset/solo-mgmt-clickhouse-shard0 --timeout=300s >/dev/null 2>&1 || true
kc -n "$SOLO_MGMT_NS" rollout status deploy/solo-enterprise-ui --timeout=300s >/dev/null 2>&1 \
  && ok "Enterprise UI ready (Keycloak SSO)" || warn "Enterprise UI not Ready in 5m — check: kc -n $SOLO_MGMT_NS get pods"

step "Exposing ClickHouse on the kind node (optional; for direct queries)"
kc apply -f "$LAB_ROOT/yaml/clickhouse-nodeport.yaml" >/dev/null
ok "ClickHouse NodePort ${CLICKHOUSE_NODEPORT} -> ${CLICKHOUSE_SVC}:${CLICKHOUSE_NATIVE_PORT}"
step "Telemetry + Enterprise UI ready"
echo "  Tracing console: http://localhost:18090 (./scripts/open-consoles.sh; login alice/alice)" >&2

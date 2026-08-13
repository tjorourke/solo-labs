#!/usr/bin/env bash
# Solo Enterprise management plane: the agentgateway observability console (/age: traffic,
# distributed traces, cost) plus the telemetry collector and ClickHouse that back it.
#
#   ./scripts/management.sh up       install the management chart + wire tracing
#   ./scripts/management.sh status   what is running
#   ./scripts/management.sh down      remove it
#
# The gateway chart does NOT ship the console or the collector. They come from the separate
# `management` chart (kagent-enterprise Solo Enterprise management plane). It installs a
# Service named solo-enterprise-telemetry-collector, an OTel collector whose traces pipeline
# writes to a bundled ClickHouse (platformdb.otel_traces_json), and solo-enterprise-ui (the
# /age console). yaml/35-tracing.yaml points the gateway's OTel export at that collector by
# name, so the release MUST live in agentgateway-system for the name to resolve unchanged.
#
# Runs after agentgateway. Verified against agentgateway v2026.7.0 + management 0.5.0.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NS=agentgateway-system
MGMT_VERSION="${MGMT_VERSION:-0.5.0}"
MGMT_CHART="oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

license() {
  if [ -z "${AGENTGATEWAY_LICENSE_KEY:-}${SOLO_LICENSE_KEY:-}" ]; then
    # shellcheck disable=SC1090
    [ -n "${SOVEREIGN_ENV_FILE:-}" ] && [ -f "$SOVEREIGN_ENV_FILE" ] && . "$SOVEREIGN_ENV_FILE" >/dev/null 2>&1 || true
  fi
  LIC="${AGENTGATEWAY_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
  # Fall back to the key the gateway release already holds, so this script is self-sufficient.
  [ -n "$LIC" ] || LIC="$(helm_ get values enterprise-agentgateway -n "$NS" -o json 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("licensing",{}).get("licenseKey",""))' 2>/dev/null)"
  [ -n "$LIC" ] || { echo "error: no licence; set AGENTGATEWAY_LICENSE_KEY or SOVEREIGN_ENV_FILE" >&2; exit 1; }
}

case "${1:-status}" in
  up)
    license
    # The unified console (solo-enterprise-ui + ui-backend) logs in against the same Keycloak
    # realm as the other consoles. The ui-backend validates tokens as a confidential client;
    # its secret is the realm's kagent-backend client secret, read from the committed realm
    # source and written to the Secret the chart's ui.backend.oidc.secretRef points at. Keycloak
    # (the idp phase) must be up first so the realm exists; the secret value itself is static.
    echo "==> ui-backend OIDC secret (kagent-backend client) in $NS"
    UI_SECRET="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(next(c["secret"] for c in d["clients"] if c["clientId"]=="kagent-backend"))' "$HERE/yaml/37-keycloak-realm.json")"
    [ -n "$UI_SECRET" ] || { echo "error: no kagent-backend client secret in the realm JSON" >&2; exit 1; }
    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kc -n "$NS" create secret generic ui-backend-oidc-secret \
      --from-literal=clientSecret="$UI_SECRET" --dry-run=client -o yaml | kc apply -f - >/dev/null

    echo "==> Solo Enterprise management plane $MGMT_VERSION (collector + ClickHouse + /age console)"
    # cost-management is a feature flag, off by default. istio.ambient + multiCluster default
    # ON in this chart; both are wrong here (we do not want the console pods enmeshed, and this
    # is a single cluster). service.type defaults to LoadBalancer, which would spin an ELB per
    # Service; ClusterIP keeps every console behind the one sovereign-gateway on its own
    # hostname, per the lab's DNS convention. ClickHouse asks for 2 CPU by default, which does
    # not fit the platform nodes with the rest of the stack on them, so it is trimmed here.
    #
    # The oidc/rbac/ui block is what makes the console log in and show data: oidc.issuer is the
    # external Keycloak hostname (matched character-for-character to yaml/32); roleMapping maps
    # realm groups to console roles; ui.backend/frontend use the kagent-backend / kagent-ui
    # clients; and the two extraEnvs let ui-backend trust the private edge cert on the OIDC hop
    # (OIDC_INSECURE_SKIP_VERIFY) and validate agent SA tokens via TokenReview (K8S_TOKEN_REVIEW),
    # without which the console shows "no bearer token" and the agents tab 401s.
    helm_ upgrade --install management "$MGMT_CHART" \
      -n "$NS" --version "$MGMT_VERSION" \
      --set cluster="$CLUSTER" \
      --set products.agentgateway.enabled=true \
      --set products.agentgateway.namespace="$NS" \
      --set products.agentgateway.features.cost-management=true \
      --set products.agentgateway.features.cost-management-writes=true \
      --set products.kagent.enabled=true \
      --set products.kagent.namespace=kagent \
      --set licensing.licenseKey="$LIC" \
      --set istio.ambient.enabled=false \
      --set platform.multiCluster.enabled=false \
      --set service.type=ClusterIP \
      --set oidc.issuer="https://keycloak.sovereign.local/realms/sovereign" \
      --set-string oidc.roleMapping.roleMappings.admin=global.Admin \
      --set-string oidc.roleMapping.roleMappings.platform=global.Writer \
      --set-string oidc.roleMapping.roleMappings.research=global.Reader \
      --set ui.backend.oidc.clientId=kagent-backend \
      --set ui.backend.oidc.secretRef=ui-backend-oidc-secret \
      --set ui.frontend.oidc.clientId=kagent-ui \
      --set-string ui.backend.extraEnvs.OIDC_INSECURE_SKIP_VERIFY=true \
      --set-string ui.backend.extraEnvs.K8S_TOKEN_REVIEW=true \
      --set clickhouse.persistentVolume.enabled=true \
      --set clickhouse.persistentVolume.storageClass=gp3 \
      --set clickhouse.resources.requests.cpu=750m \
      --set clickhouse.resources.requests.memory=2Gi \
      --set clickhouse.resources.limits.cpu=2 \
      --set clickhouse.resources.limits.memory=4Gi \
      --wait --timeout 10m >/dev/null
    echo "    waiting for ClickHouse + the console"
    kc -n "$NS" rollout status statefulset/management-clickhouse-shard0 --timeout=300s
    kc -n "$NS" rollout status deploy/solo-enterprise-ui --timeout=300s || true

    # The gateway's OTel export needs the tracing policy applied AFTER the collector exists,
    # or it attaches to nothing. This is the step the lab was missing.
    echo "==> wiring the gateway's OTel traces to the collector"
    kc apply -f "$HERE/yaml/35-tracing.yaml" >/dev/null
    # The console gets its own hostname through the gateway (age.sovereign.local), with the
    # same Permissive-JWT exemption as the other consoles.
    kc apply -f "$HERE/yaml/46-ui-routes.yaml" -f "$HERE/yaml/47-ui-auth-exempt.yaml" >/dev/null
    echo "    console at age.sovereign.local (/age, /age/cost-management). Drive traffic, then:"
    echo "    $0 traces"
    ;;

  traces)
    echo "== trace rows in ClickHouse (rising count = collector -> ClickHouse works)"
    kc -n "$NS" exec statefulset/management-clickhouse-shard0 -- \
      clickhouse-client -q "SELECT count() FROM platformdb.otel_traces_json" 2>/dev/null \
      || echo "  (ClickHouse not ready, or no traces yet)"
    ;;

  status)
    kc -n "$NS" get pods 2>/dev/null | grep -iE 'management|clickhouse|solo-enterprise|collector' || echo "  not installed"
    ;;

  down)
    helm_ uninstall management -n "$NS" >/dev/null 2>&1 || true
    echo "management plane removed (the tracing policy + console routes are left; they no-op without the collector)"
    ;;

  *) echo "usage: $0 {up|status|traces|down}"; exit 1 ;;
esac

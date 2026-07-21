#!/usr/bin/env bash
# agw-install.sh — Solo Enterprise for agentgateway, the L7 data plane this lab
# runs as its ambient WAYPOINT (GatewayClass enterprise-agentgateway-waypoint).
# ztunnel keeps proving workload identity at L4; agentgateway enforces L7 —
# JWT, CEL authorization, routing, rate limiting — with the ztunnel-proven
# identity available to policy as source.identity.*.
#
# One shared-CRD note: gloo-platform-crds (the optional Gloo UI step) and
# enterprise-agentgateway-crds both ship authconfigs.extauth.solo.io and
# ratelimitconfigs.ratelimit.solo.io. Helm refuses to adopt CRDs owned by
# another release, so if the Gloo UI went in first, hand those two CRDs to the
# agentgateway release before installing.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl; require helm
load_secrets
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || \
  die "AGENTGATEWAY_LICENSE_KEY not set — export it or point SECRETS_FILE at a file that does"

step "Shared CRDs: hand authconfigs + ratelimitconfigs to the agentgateway release (Gloo UI installed first)"
for crd in authconfigs.extauth.solo.io ratelimitconfigs.ratelimit.solo.io; do
  owner="$(kc get crd "$crd" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
  if [[ "$owner" == "gloo-platform-crds" ]]; then
    kc annotate crd "$crd" \
      meta.helm.sh/release-name=agentgateway-crds \
      meta.helm.sh/release-namespace=agentgateway-system --overwrite >/dev/null
    log "re-annotated $crd -> agentgateway-crds"
  fi
done
ok "CRD ownership settled"

step "Helm: enterprise-agentgateway CRDs $AGW_VERSION"
helm --kube-context "$CTX" upgrade -i agentgateway-crds \
  "oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds" \
  -n agentgateway-system --create-namespace --version "$AGW_VERSION" --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Helm: enterprise-agentgateway control plane $AGW_VERSION"
# clusterName must match the mesh cluster id (ISTIO_META_CLUSTER_ID on ztunnel;
# 'Kubernetes' on this plain kind install) or the waypoint cannot fetch certs.
helm --kube-context "$CTX" upgrade -i agentgateway \
  "oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway" \
  -n agentgateway-system --version "$AGW_VERSION" \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --set clusterName=Kubernetes \
  --wait --timeout 5m >/dev/null
kc -n agentgateway-system rollout status deploy/enterprise-agentgateway --timeout=120s >/dev/null
ok "enterprise-agentgateway running; GatewayClasses: enterprise-agentgateway + enterprise-agentgateway-waypoint"

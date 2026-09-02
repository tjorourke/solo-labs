#!/usr/bin/env bash
# 02-peering.sh — link the two meshes: an east-west gateway per cluster on an
# internal NLB (peering chart), then `istioctl multicluster link`, then check.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm
require_license; require_aws; require_contexts; require_istioctl

for c in "$CLUSTER_A" "$CLUSTER_B"; do
  step "[$c] east-west gateway (internal NLB)"
  kubectl --context "$c" create namespace "$EW_NS" --dry-run=client -o yaml | kubectl --context "$c" apply -f - >/dev/null
  sed -e "s/CLUSTER/$c/g" -e "s/NETWORK/$MESH_NETWORK/g" "$YAML_DIR/peering/eastwest-values.yaml" \
    | helm --kube-context "$c" upgrade -i istio-eastwest "$ISTIO_HELM_REPO/peering" \
        -n "$EW_NS" --version "$SOLO_ISTIO_VERSION" --wait --timeout 5m -f - >/dev/null
  host="$(wait_lb_host "$c" "$EW_NS" istio-eastwest)" || die "[$c] no NLB hostname for istio-eastwest"
  ok "[$c] istio-eastwest -> $host"
done

step "Pre-check both clusters"
"$ISTIOCTL" multicluster check --contexts "$CLUSTER_A,$CLUSTER_B" --precheck || true

step "Link (bi-directional): creates an istio-remote Gateway in each cluster pointing at the peer"
show "$ISTIOCTL" multicluster link --namespace "$EW_NS" --contexts "$CLUSTER_A,$CLUSTER_B"

step "Wait for the peer gateways to programme"
for c in "$CLUSTER_A" "$CLUSTER_B"; do
  kubectl --context "$c" -n "$EW_NS" wait gateway --all --for=condition=Programmed --timeout=300s >/dev/null
  kubectl --context "$c" -n "$EW_NS" get gateway
done

step "Check"
"$ISTIOCTL" multicluster check --contexts "$CLUSTER_A,$CLUSTER_B"

#!/usr/bin/env bash
# Install OSS kgateway (no license needed) and create the Gateway.
source "$(dirname "$0")/lib.sh"
step "Installing OSS kgateway ${KGW_VERSION}"
helm --kube-context "$CTX" upgrade -i kgateway-crds \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds --version "$KGW_VERSION" \
  -n kgateway-system --create-namespace --wait
helm --kube-context "$CTX" upgrade -i kgateway \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway --version "$KGW_VERSION" \
  -n kgateway-system --wait
k -n kgateway-system rollout status deploy/kgateway --timeout=120s

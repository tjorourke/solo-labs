#!/usr/bin/env bash
# Install Solo Enterprise for agentgateway on the OpenShift cluster, following
# the KB article: do NOT apply the Gateway API CRDs (OpenShift owns them at
# 1.3.0, which is inside agentgateway's supported 1.3-1.5 range). Install only
# agentgateway's own CRD chart and the control plane.
#
# Prereqs: KUBECONFIG set; source ../env.sh (AGENTGATEWAY_LICENSE_KEY, AGW_VERSION).
set -euo pipefail
: "${AGENTGATEWAY_LICENSE_KEY:?}"; AGW_VERSION="${AGW_VERSION:-v2026.6.1}"

# Confirm the cluster's Gateway API version is in range (1.3-1.5). 4.21 = 1.3.0.
oc get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='Gateway API bundle: {.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'

# (Skipped on purpose: kubectl apply standard-install.yaml. OpenShift's Ingress
#  Operator owns the Gateway API CRDs; applying your own degrades it and can
#  block cluster upgrades.)

# agentgateway's OWN CRDs (agentgateway.dev / ExtAuth / RateLimit) - not Gateway API.
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace agentgateway-system --version "$AGW_VERSION"

# Control plane.
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n agentgateway-system --version "$AGW_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"

oc -n agentgateway-system rollout status deploy/enterprise-agentgateway --timeout=180s

# Both implementations now coexist, selected by GatewayClass controllerName.
# Nothing on the OpenShift side is disabled.
oc get gatewayclass

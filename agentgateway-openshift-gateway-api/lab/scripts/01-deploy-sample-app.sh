#!/usr/bin/env bash
# Deploy the sample app behind OpenShift's OWN Gateway API (the 1.3.0 CRDs the
# cluster manages). Proves Gateway API works on OpenShift before we migrate.
#
# Prereqs: KUBECONFIG set to the cluster; source ../env.sh (APP_HOST).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; Y="$HERE/yaml"
: "${APP_HOST:?}"; export APP_HOST

# 0. Confirm the cluster's Gateway API version (expect v1.3.0 on OCP 4.21).
#    Note: these CRDs are installed/owned by the cluster Ingress Operator.
#    Do NOT apply upstream standard-install.yaml on OpenShift.
oc get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='Gateway API bundle: {.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'

# 1. Backend app.
oc apply -f "$Y/00-backend.yaml"

# 2. GatewayClass -> triggers the Ingress Operator to install OSSM/Istio via OLM.
oc apply -f "$Y/10-openshift-gatewayclass.yaml"
echo "waiting for GatewayClass Accepted (OSSM install, a few min)..."
until [ "$(oc get gatewayclass openshift-default -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')" = "True" ]; do sleep 10; done

# 3. Gateway (MUST be in openshift-ingress) + HTTPRoute (in the app namespace).
oc apply -f "$Y/20-openshift-gateway.yaml"
envsubst < "$Y/30-httproute.yaml" | oc apply -f -   # parentRef to hello-agw is ignored until that gateway exists
echo "waiting for Gateway Programmed + LB..."
until [ -n "$(oc -n openshift-ingress get svc hello-gw-openshift-default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)" ]; do sleep 10; done
LB="$(oc -n openshift-ingress get svc hello-gw-openshift-default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# 4. Cross-zone load balancing: the cluster has 2 workers (2 AZs) but the ELB
#    spans 3 AZ subnets, so the empty-AZ node blackholes ~1/3 of requests
#    unless cross-zone LB is on. Enable it for a clean external test.
oc -n openshift-ingress annotate svc hello-gw-openshift-default \
  service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled=true --overwrite

echo "OpenShift gateway LB: $LB"
echo "test:  curl -H 'Host: ${APP_HOST}' http://$LB/"
echo "(then point ${APP_HOST} at $LB in DNS to use the hostname)"

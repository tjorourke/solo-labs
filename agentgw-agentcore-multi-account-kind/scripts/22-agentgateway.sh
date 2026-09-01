#!/usr/bin/env bash
# 22-agentgateway.sh — Solo Enterprise for agentgateway (CRDs + control plane),
# then the SINGLE Gateway with its ambient AWS identity:
#   - Secret aws-ambient: the tofu-created agw-ambient IAM user's key
#   - EnterpriseAgentgatewayParameters: injects the key as env into the proxy
#     pod (spec.env). assumeRole uses these as the STS source credentials;
#     secretRef would be mutually exclusive with assumeRole.
#   - Gateway agentgateway-proxy: one HTTP :80 listener, NodePort 30080
#     (kind maps host :80), serving BOTH the platform consoles and the
#     /portfolio-* agent routes. In production the ambient identity is the
#     gateway's IRSA role; the parametersRef Secret is the kind stand-in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets
load_tofu_env

step "Authenticating to the chart registry ($GAR_HOST)"
ensure_gar_auth "$GAR_HOST"; ok "registry auth ready"

step "Installing enterprise-agentgateway CRDs ($AGW_VERSION)"
helm --kube-context "$CTX" upgrade --install enterprise-agentgateway-crds \
  "$AGW_CRDS_CHART" --version "$AGW_VERSION" \
  --namespace "$GW_NS" --create-namespace --wait --timeout 3m >/dev/null
ok "CRDs installed"

step "Installing enterprise-agentgateway control plane ($AGW_VERSION)"
helm_install_with_progress enterprise-agentgateway "$AGW_CHART" "$GW_NS" \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 5m
ok "control plane installed"

step "Verifying the installed CRDs carry assumeRole (never trust the pin blindly)"
kc get crd enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io -o json 2>/dev/null \
  | jq -e '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.policies.properties.auth.properties.aws.properties.assumeRole' >/dev/null \
  || die "installed EnterpriseAgentgatewayBackend schema lacks policies.auth.aws.assumeRole — bump AGW_VERSION"
ok "schema has policies.auth.aws.assumeRole"

step "Ambient AWS identity for the proxy (Secret + parameters)"
kc create namespace "$GW_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$GW_NS" create secret generic aws-ambient \
  --from-literal=AWS_ACCESS_KEY_ID="$AGW_AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AGW_AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agw-ambient-identity
  namespace: ${GW_NS}
spec:
  env:
    - name: AWS_ACCESS_KEY_ID
      valueFrom: { secretKeyRef: { name: aws-ambient, key: AWS_ACCESS_KEY_ID } }
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom: { secretKeyRef: { name: aws-ambient, key: AWS_SECRET_ACCESS_KEY } }
    - name: AWS_REGION
      value: ${PORTFOLIO_A_REGION}
EOF
ok "aws-ambient Secret + EnterpriseAgentgatewayParameters applied"

step "Creating the single Gateway '${GW_NAME}'"
kc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${GW_NS}
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: agw-ambient-identity
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
EOF
log "waiting for the proxy deployment '$GW_NAME' to provision..."
wait_deploy "$GW_NS" "$GW_NAME" 300s \
  || warn "proxy '$GW_NAME' not Available yet — check: kubectl --context $CTX -n $GW_NS get pods"

step "Pinning the gateway Service to NodePort ${GW_HTTP_NODEPORT} (kind host :80)"
GW_SVC=""
for _ in $(seq 1 40); do
  GW_SVC="$(kc -n "$GW_NS" get svc -l gateway.networking.k8s.io/gateway-name="$GW_NAME" -o name 2>/dev/null | head -1)"
  [[ -n "$GW_SVC" ]] && break; sleep 3
done
[[ -n "$GW_SVC" ]] || die "gateway Service not found for ${GW_NAME}"
kc -n "$GW_NS" patch "$GW_SVC" --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
  {\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${GW_HTTP_NODEPORT}}
]" >/dev/null && ok "${GW_SVC} -> NodePort ${GW_HTTP_NODEPORT}"

step "Verifying the proxy pod carries the ambient identity"
POD="$(kc -n "$GW_NS" get pods -l gateway.networking.k8s.io/gateway-name="$GW_NAME" -o name | head -1)"
kc -n "$GW_NS" get "$POD" -o jsonpath='{.spec.containers[0].env[*].name}' | grep -q AWS_ACCESS_KEY_ID \
  || die "proxy pod has no AWS_ACCESS_KEY_ID env — parametersRef not applied"
ok "proxy pod env includes the aws-ambient credentials"
echo "  Next: ./scripts/23-ingress.sh" >&2

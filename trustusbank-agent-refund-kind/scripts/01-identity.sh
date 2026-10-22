#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
if ! kind get clusters | python3 -c 'import sys;sys.exit("trustusbank-lab" not in sys.stdin.read().split())'; then
  kind create cluster --config "$LAB/kind/cluster.yaml" --wait=5m
fi
for component in kube-apiserver kube-controller-manager kube-scheduler; do
  k -n kube-system wait --for=condition=Ready pod -l "component=$component" --timeout=300s >/dev/null
done
k -n kube-system scale deployment coredns --replicas=1 --dry-run=server >/dev/null
k -n kube-system scale deployment coredns --replicas=1
if k -n local-path-storage get deployment local-path-provisioner >/dev/null 2>&1; then
  k -n local-path-storage delete deployment local-path-provisioner --dry-run=server >/dev/null
  k -n local-path-storage delete deployment local-path-provisioner --wait=false
fi
# Reuse the host cache so a cold node does not race a registry TLS handshake.
image=$(python3 -c 'import sys,yaml;print(next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d["kind"]=="Deployment")["spec"]["template"]["spec"]["containers"][0]["image"])' "$LAB/yaml/keycloak.yaml")
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
platform="linux/$(k get node trustusbank-lab-control-plane -o jsonpath='{.status.nodeInfo.architecture}')"
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
docker image save --platform "$platform" -o "$archive" "$image"
kind load image-archive "$archive" --name trustusbank-lab
rm -f "$archive"
trap - EXIT
apply "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
R=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway-crds "$R/enterprise-agentgateway-crds" -n agentgateway-system --create-namespace --version "$AGW_VERSION" --wait
apply "$LAB/yaml/gateway-runtime.yaml"
set -a
source "${SECRETS_FILE:-$HOME/.solo/secrets.env}" >/dev/null 2>&1
set +a
: "${AGENTGATEWAY_LICENSE_KEY:?licence required}"
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | k -n agentgateway-system create secret generic enterprise-agentgateway-license --from-file=enterprise-agentgateway-license-key=/dev/stdin --dry-run=client -o yaml | apply_stdin
for ns in keycloak bank; do k create namespace "$ns" --dry-run=client -o yaml | apply_stdin; done
k -n keycloak create configmap realm --from-file="$LAB/yaml/realm-bank.json" --dry-run=client -o yaml | apply_stdin
apply "$LAB/yaml/keycloak.yaml"
k -n keycloak rollout status deploy/keycloak --timeout=300s
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway "$R/enterprise-agentgateway" -n agentgateway-system --version "$AGW_VERSION" --reset-values -f "$LAB/yaml/values.yaml" --wait --timeout=6m
apply "$LAB/yaml/gateway-runtime.yaml"
apply "$LAB/yaml/identities.yaml"
tools
# Helm readiness can precede the STS listener while its signing key starts up.
incurl --fail --retry 20 --retry-connrefused --retry-delay 2 --retry-max-time 90 "$STS/.well-known/jwks.json" >/dev/null
chain
printf '%s' "$H1" | claims
result=$(incurl -w '\nHTTP %{http_code}\n' "$KC" -d grant_type=password -d client_id=payments-ops -d username=bob -d password=wrong)
printf '%s\n' "$result"
[[ "$result" == *'HTTP 401'* ]]

#!/usr/bin/env bash
# Step 3: Solo Enterprise for kagent with the agentgateway STS, on the running xcloud-mcp cluster.
# Run after scripts/up.sh. Idempotent. Never tears anything down. Needs the Keycloak port-forward on 8180.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
source scripts/lib.sh
set -a; source "${SECRETS_FILE:-$HOME/.solo/secrets.env}" >/dev/null 2>&1; set +a
KAGENT_ENT_VERSION=${KAGENT_ENT_VERSION:-0.5.16}
KAGENT_CHARTS=oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts
MGMT_CHART=oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management
# Licence order: KAGENT_ENT_LICENSE_KEY, then SOLO_LICENSE_KEY. Only the variable name and a sha prefix are printed.
if [[ -n ${KAGENT_ENT_LICENSE_KEY:-} ]]; then KAGENT_LICENSE_SOURCE=KAGENT_ENT_LICENSE_KEY
elif [[ -n ${SOLO_LICENSE_KEY:-} ]]; then KAGENT_LICENSE_SOURCE=SOLO_LICENSE_KEY; KAGENT_ENT_LICENSE_KEY=$SOLO_LICENSE_KEY
fi
: "${KAGENT_ENT_LICENSE_KEY:?Set KAGENT_ENT_LICENSE_KEY (or SOLO_LICENSE_KEY) in the secrets file}"
: "${OPENAI_API_KEY:?Set OPENAI_API_KEY in the secrets file}"
k() { kubectl --context "$CTX" "$@"; }
secret_stdin() { # NAMESPACE NAME KEY, value on stdin
  k -n "$1" create secret generic "$2" --from-file="$3=/dev/stdin" --dry-run=client -o yaml | k apply -f - >/dev/null
}

echo '== 1. agentgateway STS (tokenExchange on port 7777)'
helm --kube-context "$CTX" upgrade -i enterprise-agentgateway "$AGW_CHARTS/enterprise-agentgateway" --version "$AGW_VERSION" \
  -n agentgateway-system -f yaml/values.yaml -f yaml/sts-values.yaml --wait --timeout 6m >/dev/null
k -n agentgateway-system get svc enterprise-agentgateway -o jsonpath='{.spec.ports[*].port}' | grep -qw 7777

echo '== 2. Keycloak clients for the Solo UI'
k create namespace kagent --dry-run=client -o yaml | k apply -f - >/dev/null
python3 kagent/keycloak-clients.py

echo "== 3. Secrets (licence from $KAGENT_LICENSE_SOURCE, sha256 $(printf '%s' "$KAGENT_ENT_LICENSE_KEY" | shasum -a 256 | cut -c1-8); model key from OPENAI_API_KEY)"
printf '%s' "$KAGENT_ENT_LICENSE_KEY" | secret_stdin kagent kagent-enterprise-license enterprise-kagent-license-key
printf '%s' "$KAGENT_ENT_LICENSE_KEY" | secret_stdin agentgateway-system kagent-management-license license-key
printf '%s' "$OPENAI_API_KEY" | secret_stdin kagent kagent-openai OPENAI_API_KEY

echo "== 4. kagent-enterprise $KAGENT_ENT_VERSION"
helm --kube-context "$CTX" upgrade -i kagent-crds "$KAGENT_CHARTS/kagent-enterprise-crds" -n kagent \
  --version "$KAGENT_ENT_VERSION" --wait --timeout 5m >/dev/null
helm template kagent "$KAGENT_CHARTS/kagent-enterprise" -n kagent --version "$KAGENT_ENT_VERSION" \
  -f kagent/kagent-values.yaml | k apply --dry-run=server -f - >/dev/null
helm --kube-context "$CTX" upgrade -i kagent "$KAGENT_CHARTS/kagent-enterprise" -n kagent --version "$KAGENT_ENT_VERSION" \
  -f kagent/kagent-values.yaml --wait --timeout 8m >/dev/null
k -n kagent rollout status deploy/kagent-controller --timeout=240s

echo "== 5. Solo UI (management $KAGENT_ENT_VERSION)"
# The management chart bundles management-crds, which includes enterpriseagentgatewayrbacpolicies. That CRD is
# already owned by the enterprise-agentgateway-crds release, so Helm refuses it. Turn the bundled CRDs off
# (management-crds.enabled in kagent/management-values.yaml) and apply only the CRDs the cluster does not have.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
helm pull "$MGMT_CHART" --version "$KAGENT_ENT_VERSION" --untar -d "$tmp" >/dev/null 2>&1
helm template management-crds "$tmp/management/charts/management-crds" | python3 -c '
import sys, yaml, subprocess
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "CustomResourceDefinition"]
have = subprocess.run(["kubectl","--context","'"$CTX"'","get","crd","-o","name"],capture_output=True,text=True).stdout.split()
print(yaml.safe_dump_all([d for d in docs if "customresourcedefinition.apiextensions.k8s.io/"+d["metadata"]["name"] not in have]))' > "$tmp/crds.yaml"
if grep -q CustomResourceDefinition "$tmp/crds.yaml"; then
  k apply --dry-run=server -f "$tmp/crds.yaml" >/dev/null && k apply -f "$tmp/crds.yaml" >/dev/null
fi
helm template management "$MGMT_CHART" -n agentgateway-system --version "$KAGENT_ENT_VERSION" \
  -f kagent/management-values.yaml | k apply --dry-run=server -f - >/dev/null
helm --kube-context "$CTX" upgrade -i management "$MGMT_CHART" -n agentgateway-system --version "$KAGENT_ENT_VERSION" \
  -f kagent/management-values.yaml --wait --timeout 12m >/dev/null
k -n agentgateway-system rollout status deploy/solo-enterprise-ui --timeout=240s

echo '== 6. Licence lines (no values)'
k -n kagent logs deploy/kagent-controller --tail=400 2>/dev/null | grep -iE 'licen' | sed -E 's/"(ts|time)":"[^"]*",//' | tail -3 || true
echo "Solo UI: kubectl --context $CTX -n agentgateway-system port-forward svc/solo-enterprise-ui 19480:80, then http://localhost:19480"

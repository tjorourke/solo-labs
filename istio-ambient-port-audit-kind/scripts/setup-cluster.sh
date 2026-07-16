#!/usr/bin/env bash
# setup-cluster.sh — stands up the infrastructure that is too fiddly to
# copy-paste (kind, image loading, Helm, the operator) and leaves the mesh in
# AMBIENT mode with ztunnel writing JSON access logs. Everything after this —
# the app, the policy, and the audit stack — is plain YAML you apply yourself
# from the README, so you can read and talk through every change.
#
# What it does:
#   1. kind cluster (1 control-plane + 2 workers)
#   2. Gateway API CRDs (+ remove the safe-upgrades policy so the operator can
#      manage its own bundled CRDs)
#   3. Pre-pull the Solo Istio images on the host and kind-load them
#   4. Gloo Operator (Helm) + solo-istio-license Secret
#   5. ServiceMeshController, dataplaneMode: Ambient → istiod + istio-cni + ztunnel
#   6. Wire SOLO_LICENSE_KEY onto istiod
#   7. LOG_FORMAT=json on the ztunnel DaemonSet, so the access logs the
#      collector parses are structured instead of key=value text
# Idempotent. Needs docker, kind, kubectl, helm, gcloud (authenticated) and
# SOLO_ISTIO_LICENSE_KEY (export it, or point SECRETS_FILE at a file that does).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require kind; require kubectl; require helm; require docker; require gcloud
check_docker; check_gcloud; require_secrets

step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists"
else
  kind create cluster --config "$LAB_ROOT/kind/cluster.yaml" >/dev/null
  ok "cluster '$CLUSTER_NAME' created"
fi
kc wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kc apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
# Gateway API >= v1.5.0 ships a safe-upgrades ValidatingAdmissionPolicy that
# blocks the Gloo Operator from reconciling its own bundled Gateway API CRDs.
# The operator manages those CRDs itself, so remove the policy.
kc delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
kc delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
ok "Gateway API CRDs installed (safe-upgrades policy removed for the operator)"

step "Pre-pulling Solo Istio images ($ISTIO_VERSION) and loading into kind"
# Load via `docker save --platform | kind load image-archive`: with Docker's
# containerd image store, `kind load docker-image` fails ("content digest …
# not found") because it imports the whole multi-platform index.
__tar_tmp="$(mktemp -d)"; trap 'rm -rf "$__tar_tmp"' EXIT
while read -r img; do
  docker image inspect "$img" >/dev/null 2>&1 || { log "pulling $img …"; docker pull --quiet "$img" >/dev/null; }
  tar="$__tar_tmp/$(echo "$img" | tr '/:' '__').tar"
  docker save --platform "$KIND_PLATFORM" "$img" -o "$tar"
  log "loading $(basename "$img") into kind …"
  kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null
  rm -f "$tar"
done < <(solo_istio_images)
ok "Solo Istio images loaded"

step "Installing Gloo Operator $GLOO_OPERATOR_VERSION"
helm --kube-context "$CTX" upgrade --install gloo-operator "$OPERATOR_CHART" \
  --namespace "$GLOO_SYSTEM_NS" --create-namespace --version "$GLOO_OPERATOR_VERSION" \
  --wait --timeout 5m >/dev/null
ok "Gloo Operator ready"

step "Creating solo-istio-license Secret in $ISTIO_SYSTEM_NS"
kc create namespace "$ISTIO_SYSTEM_NS" >/dev/null 2>&1 || true
kc -n "$ISTIO_SYSTEM_NS" create secret generic solo-istio-license \
  --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "license Secret created"

step "Applying ServiceMeshController (dataplaneMode: Ambient)"
kapply "$LAB_ROOT/yaml/00-mesh/smc-ambient.yaml"
end=$(( $(date +%s) + 300 ))
until kc -n "$ISTIO_SYSTEM_NS" get deploy 2>/dev/null | grep -q istiod; do
  [[ $(date +%s) -ge $end ]] && die "istiod not created within 5m"
  sleep 5
done
ISTIOD="$(kc -n "$ISTIO_SYSTEM_NS" get deploy -o name | grep istiod | head -1 | cut -d/ -f2)"
if ! kc -n "$ISTIO_SYSTEM_NS" get deploy "$ISTIOD" \
     -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -q SOLO_LICENSE_KEY; then
  kc -n "$ISTIO_SYSTEM_NS" patch deployment "$ISTIOD" --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/env/-",
     "value":{"name":"SOLO_LICENSE_KEY","valueFrom":{"secretKeyRef":{"name":"solo-istio-license","key":"license"}}}}
  ]' >/dev/null
fi
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy "$ISTIOD" --timeout=180s >/dev/null
ok "istiod ready (ambient mode), SOLO_LICENSE_KEY wired"

step "Waiting for the ambient node components (istio-cni + ztunnel)"
end=$(( $(date +%s) + 300 ))
until kc -n "$ISTIO_SYSTEM_NS" get daemonset ztunnel >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "ztunnel DaemonSet not created within 5m"
  sleep 5
done
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/istio-cni-node --timeout=180s >/dev/null
ok "istio-cni + ztunnel running on every node"

step "Switching ztunnel access logs to JSON (LOG_FORMAT=json)"
# ztunnel formats all its output, access logs included, through one tracing
# subscriber; LOG_FORMAT=json switches it to the standard Istio JSON encoding
# (verified in ztunnel src/telemetry.rs). The ServiceMeshController has no env
# passthrough field, so patch the DaemonSet the operator rendered — the same
# pattern the operator tolerates for the istiod license env above.
if ! kc -n "$ISTIO_SYSTEM_NS" get daemonset ztunnel \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LOG_FORMAT")].value}' | grep -q json; then
  kc -n "$ISTIO_SYSTEM_NS" patch daemonset ztunnel --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/env/-",
     "value":{"name":"LOG_FORMAT","value":"json"}}
  ]' >/dev/null
fi
kc -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
ok "ztunnel emitting JSON access logs"

echo
ok "Cluster ready. Solo Istio $ISTIO_VERSION in AMBIENT mode, JSON access logs on."
log "Now follow the README: deploy the app, the policy, then the audit stack."

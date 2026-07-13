#!/usr/bin/env bash
# 01-cluster.sh — kind cluster + Solo Istio in SIDECAR mode via the Gloo Operator.
#
#   1. kind cluster (1 control-plane + 2 workers)
#   2. Gateway API CRDs (needed later for waypoints + HTTPRoute)
#   3. Pre-pull Solo Istio images on the host and kind-load them (no in-cluster
#      pull secret needed — the host has gcloud creds)
#   4. Gloo Operator (Helm)
#   5. solo-istio-license Secret in istio-system
#   6. ServiceMeshController CR, dataplaneMode: Sidecar
#   7. Wire SOLO_LICENSE_KEY onto istiod
# Idempotent.
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
# blocks the Gloo Operator from reconciling its own bundled Gateway API CRDs
# ("Installing CRDs with version before v1.5.0 is prohibited"). The operator
# manages those CRDs itself, so remove the policy — the error message itself
# recommends this. Without it the ServiceMeshController stays PENDING forever.
kc delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
kc delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
ok "Gateway API CRDs installed (safe-upgrades policy removed for the operator)"

step "Pre-pulling Solo Istio images ($ISTIO_VERSION) and loading into kind"
# Load via `docker save | kind load image-archive` rather than
# `kind load docker-image`: with Docker's containerd image store the latter
# fails ("content digest … not found") because it tries to import the whole
# manifest list. A saved single-platform archive imports cleanly.
__tar_tmp="$(mktemp -d)"
trap 'rm -rf "$__tar_tmp"' EXIT
while read -r img; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    log "cached: $(basename "$img")"
  else
    log "pulling $img …"
    docker pull --quiet "$img" >/dev/null
  fi
  tar="$__tar_tmp/$(echo "$img" | tr '/:' '__').tar"
  # Save ONLY the node platform. Docker's containerd image store keeps a
  # multi-platform index; a full save makes kind's `ctr import --all-platforms`
  # fail on the other platform's missing digest. --platform pins one.
  docker save --platform "$KIND_PLATFORM" "$img" -o "$tar"
  log "loading $(basename "$img") into kind …"
  kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null
  rm -f "$tar"
done < <(solo_istio_images)
ok "Solo Istio images loaded"

step "Installing Gloo Operator $GLOO_OPERATOR_VERSION"
helm --kube-context "$CTX" upgrade --install gloo-operator "$OPERATOR_CHART" \
  --namespace "$GLOO_SYSTEM_NS" --create-namespace \
  --version "$GLOO_OPERATOR_VERSION" \
  --wait --timeout 5m >/dev/null
ok "Gloo Operator ready"

step "Creating solo-istio-license Secret in $ISTIO_SYSTEM_NS"
kc create namespace "$ISTIO_SYSTEM_NS" >/dev/null 2>&1 || true
kc -n "$ISTIO_SYSTEM_NS" create secret generic solo-istio-license \
  --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "license Secret created"

step "Applying ServiceMeshController (dataplaneMode: Sidecar)"
kapply "$LAB_ROOT/yaml/00-mesh/smc-sidecar.yaml"
log "waiting for istiod …"
end=$(( $(date +%s) + 300 ))
until kc -n "$ISTIO_SYSTEM_NS" get deploy 2>/dev/null | grep -q istiod; do
  [[ $(date +%s) -ge $end ]] && die "istiod not created within 5m"
  sleep 5
done
ISTIOD="$(kc -n "$ISTIO_SYSTEM_NS" get deploy -o name | grep istiod | head -1 | cut -d/ -f2)"
log "istiod deployment: $ISTIOD"

step "Wiring SOLO_LICENSE_KEY onto $ISTIOD"
if ! kc -n "$ISTIO_SYSTEM_NS" get deploy "$ISTIOD" \
     -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -q SOLO_LICENSE_KEY; then
  kc -n "$ISTIO_SYSTEM_NS" patch deployment "$ISTIOD" --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/env/-",
     "value":{"name":"SOLO_LICENSE_KEY",
              "valueFrom":{"secretKeyRef":{"name":"solo-istio-license","key":"license"}}}}
  ]' >/dev/null
  ok "SOLO_LICENSE_KEY patched"
else
  ok "SOLO_LICENSE_KEY already set"
fi
kc -n "$ISTIO_SYSTEM_NS" rollout status deploy "$ISTIOD" --timeout=180s >/dev/null
ok "istiod ready (sidecar mode)"

echo
ok "Cluster ready. Solo Istio $ISTIO_VERSION running in SIDECAR mode."
log "next: ./scripts/02-apps.sh"

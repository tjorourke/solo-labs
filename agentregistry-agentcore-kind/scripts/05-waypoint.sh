#!/usr/bin/env bash
# 05-waypoint.sh — install the data plane that lets a kagent AccessPolicy enforce
# MCP TOOL-LEVEL access (e.g. deny the `printenv` tool). A kagent AccessPolicy is
# inert on its own; enforcement happens at an agentgateway waypoint sitting in
# front of the MCP server. Standing that up needs, in order:
#
#   1. Solo Istio in AMBIENT mode  (Gloo Operator + ServiceMeshController)
#   2. Enterprise agentgateway     (provides the enterprise-agentgateway-waypoint
#                                   GatewayClass the kagent translator targets)
#   3. the kagent namespace joined to the ambient mesh
#
# Then, per demo, label the MCPServer `kagent.solo.io/waypoint=true` and apply an
# AccessPolicy — the kmcp-enterprise translator provisions the waypoint Gateway +
# HTTPRoute + AgentgatewayBackend and the controller compiles the AccessPolicy
# into an EnterpriseAgentgatewayPolicy on that backend (see accesspolicy-on.sh).
#
# This reuses the patterns proven in solo-demos: rugpull-demo (Gloo Operator +
# ServiceMeshController, single-cluster here) and agentgw-multi-cluster-kind
# (enterprise agentgateway GA v2026.5.1 + the waypoint GatewayClass).
#
# Licenses (from secrets-envs.sh / .env.local):
#   SOLO_ISTIO_LICENSE_KEY    Solo Istio (enterprise, lt: ent)
#   AGENTGATEWAY_LICENSE_KEY  enterprise agentgateway

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_secrets
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]]   || die "SOLO_ISTIO_LICENSE_KEY not set (source secrets-envs.sh or set in .env.local)"
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || die "AGENTGATEWAY_LICENSE_KEY not set (source secrets-envs.sh or set in .env.local)"
check_docker

# ── versions / charts ─────────────────────────────────────────────────────────
OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
OPERATOR_CHART="oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator"
# Solo Istio. The operator auto-appends "-solo" for distribution=Standard, so we
# pass the version WITHOUT the suffix (rugpull-demo gap #: "-solo-solo" 404s).
ISTIO_VERSION_PLAIN="${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo}"
ISTIO_VERSION="${ISTIO_VERSION_PLAIN%-solo}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
AGW_VERSION="${AGENTGATEWAY_ENTERPRISE_VERSION:-v2026.5.1}"
AGW_CHART="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway"
AGW_CRDS_CHART="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds"
GW_API_VER="${GATEWAY_API_VERSION:-v1.4.0}"

# NOTE: the SMC `version` field is the STRIPPED form (1.29.2-patch0) — the
# operator appends "-solo" for distribution=Standard. But the actual IMAGE tags
# in the registry carry "-solo" (there is no `pilot:1.29.2-patch0`, only
# `pilot:1.29.2-patch0-solo`), so pre-pull the full -solo tag to match what the
# operator deploys onto the (GAR-credential-less) kind nodes.
ISTIO_IMAGES=(
  "$ISTIO_REGISTRY/pilot:$ISTIO_VERSION_PLAIN"
  "$ISTIO_REGISTRY/proxyv2:$ISTIO_VERSION_PLAIN"
  "$ISTIO_REGISTRY/install-cni:$ISTIO_VERSION_PLAIN"
  "$ISTIO_REGISTRY/ztunnel:$ISTIO_VERSION_PLAIN"
)

# ── 1. Gateway API experimental CRDs (ambient waypoints need these) ───────────
step "Gateway API experimental CRDs ($GW_API_VER)"
# Gateway API >=1.5 standard CRDs (from 01-cluster) ship a safe-upgrades
# ValidatingAdmissionPolicy that forbids layering the experimental channel on
# top. The ambient waypoint needs experimental, so drop that policy first.
# Deleting it is eventually-consistent: the apiserver keeps enforcing a
# just-deleted policy until its admission cache resyncs (a few seconds), so an
# immediate apply can still be denied. Drop it, then retry the apply with
# backoff, re-dropping on each denial (idempotent — a fresh standard install in
# 01-cluster recreates the policy, so every re-run re-drops it).
drop_safe_upgrades() {
  kc delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
  kc delete validatingadmissionpolicy        safe-upgrades.gateway.networking.k8s.io --ignore-not-found >/dev/null 2>&1 || true
}
EXP_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_API_VER}/experimental-install.yaml"
drop_safe_upgrades
applied=0
for attempt in $(seq 1 12); do
  if kc apply --server-side --force-conflicts -f "$EXP_URL" >/tmp/gwexp.$$.log 2>&1; then applied=1; break; fi
  if grep -q 'safe-upgrades' /tmp/gwexp.$$.log 2>/dev/null; then
    log "safe-upgrades policy still enforced (attempt $attempt); re-dropping and retrying"
    drop_safe_upgrades; sleep 5
  else
    cat /tmp/gwexp.$$.log >&2; rm -f /tmp/gwexp.$$.log; die "experimental Gateway API CRD apply failed"
  fi
done
rm -f /tmp/gwexp.$$.log
[[ "$applied" == 1 ]] || die "experimental Gateway API CRDs still blocked by safe-upgrades policy after retries — delete it manually: kubectl delete validatingadmissionpolicy,validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io"
ok "Gateway API experimental CRDs applied"

# ── 2. Gloo Operator ──────────────────────────────────────────────────────────
step "Installing Gloo Operator $OPERATOR_VERSION"
ensure_gar_auth
kc create ns gloo-system --dry-run=client -o yaml | kc apply -f - >/dev/null
helm --kube-context "$CTX" upgrade --install gloo-operator "$OPERATOR_CHART" \
  --version "$OPERATOR_VERSION" -n gloo-system --wait --timeout 3m >/dev/null
ok "gloo-operator installed"

# ── 3. Pre-pull + kind-load Solo Istio images (kind has no GAR creds) ─────────
step "Pre-pulling + loading Solo Istio images ($ISTIO_VERSION_PLAIN)"
gcloud auth configure-docker us-docker.pkg.dev --quiet >/dev/null 2>&1 || true
for img in "${ISTIO_IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || { log "pulling $img"; docker pull --quiet "$img" >/dev/null; }
  log "  $CLUSTER_NAME ← $(basename "$img")"
  kind load docker-image "$img" --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
done
ok "Solo Istio images loaded into kind-$CLUSTER_NAME"

# ── 4. Solo Istio license + ServiceMeshController (ambient) ───────────────────
step "ServiceMeshController (ambient, cluster=$CLUSTER_NAME)"
kc create ns istio-system --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n istio-system create secret generic solo-istio-license \
  --from-literal=license="$SOLO_ISTIO_LICENSE_KEY" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f - <<EOF >/dev/null
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
spec:
  cluster: $CLUSTER_NAME
  network: $CLUSTER_NAME
  trustDomain: cluster.local
  version: "$ISTIO_VERSION"
  dataplaneMode: Ambient
  distribution: Standard
  installNamespace: istio-system
  scalingProfile: Demo
  trafficCaptureMode: Auto
  onConflict: Force
  image:
    registry: us-docker.pkg.dev
    repository: soloio-img/istio
EOF
log "waiting for ServiceMeshController .status.phase = SUCCEEDED"
for i in $(seq 1 60); do
  phase=$(kc get servicemeshcontroller managed-istio -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  case "$phase" in
    SUCCEEDED|INSTALLED|Installed) ok "ServiceMeshController $phase"; break ;;
    FAILED|ABORTED|Failed|Aborted) kc get servicemeshcontroller managed-istio -o jsonpath='{.status.conditions}' | sed 's/^/    /' >&2; die "ServiceMeshController failed" ;;
  esac
  sleep 5
done

# istiod alias: operator names it istiod-gloo; the EAG waypoint binary hardcodes
# CA_ADDRESS=istiod.istio-system.svc:15012. Alias so the waypoint reaches the CA.
step "istiod alias Service (operator names it istiod-gloo)"
kc apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: istiod
  namespace: istio-system
  labels: { app: istiod }
spec:
  selector: { app: istiod, istio.io/rev: gloo }
  ports:
    - { name: grpc-xds,        port: 15010, protocol: TCP }
    - { name: https-dns,       port: 15012, protocol: TCP }
    - { name: https-webhook,   port: 443,   protocol: TCP }
    - { name: http-monitoring, port: 15014, protocol: TCP }
EOF
# License env on istiod-gloo (binary reads SOLO_LICENSE_KEY from the Secret).
kc -n istio-system patch deploy istiod-gloo --type='json' \
  -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"SOLO_LICENSE_KEY\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"solo-istio-license\",\"key\":\"license\"}}}}]" 2>&1 | grep -vqE 'patched|already' || true
kc -n istio-system rollout status deploy/istiod-gloo --timeout=2m >/dev/null 2>&1 || true
ok "istiod alias + license env applied"

# ── 5. Enterprise agentgateway (provides the waypoint GatewayClass) ───────────
step "Enterprise agentgateway $AGW_VERSION CRDs"
helm --kube-context "$CTX" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
  --namespace agentgateway-system --create-namespace --version "$AGW_VERSION" --wait --timeout 3m >/dev/null
ok "agentgateway CRDs installed"

step "Enterprise agentgateway $AGW_VERSION controller"
helm --kube-context "$CTX" upgrade --install agentgateway "$AGW_CHART" \
  --namespace agentgateway-system --version "$AGW_VERSION" \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 5m >/dev/null
ok "enterprise agentgateway installed"

# GatewayClass should now exist.
log "GatewayClasses:"; kc get gatewayclass 2>/dev/null | sed 's/^/    /' >&2 || true

# Waypoint identity params. Every waypoint the kagent translator creates needs
# CLUSTER_ID + NETWORK to match istiod, or it can't fetch its cert ("request
# authenticate failure") and ztunnel can't classify the service ("no service
# found"). Setting them once on the GatewayClass (via AgentgatewayParameters)
# means every waypoint created at demo time inherits them — no per-Deployment
# patching. (CLUSTER_ID+NETWORK go in spec.env; istio.* only has trustDomain.)
step "Waypoint identity params (CLUSTER_ID + NETWORK on the waypoint GatewayClass)"
kc apply -f - <<EOF >/dev/null
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: waypoint-params
  namespace: gloo-system
spec:
  env:
    - { name: CLUSTER_ID, value: "$CLUSTER_NAME" }
    - { name: NETWORK,    value: "$CLUSTER_NAME" }
EOF
kc patch gatewayclass enterprise-agentgateway-waypoint --type=merge \
  -p '{"spec":{"parametersRef":{"group":"agentgateway.dev","kind":"AgentgatewayParameters","name":"waypoint-params","namespace":"gloo-system"}}}' >/dev/null
ok "waypoint GatewayClass wired to CLUSTER_ID/NETWORK=$CLUSTER_NAME"

# ── 6. Join the kagent namespace to the ambient mesh ──────────────────────────
step "Enrolling the kagent namespace in the ambient mesh"
kc label ns kagent istio.io/dataplane-mode=ambient --overwrite >/dev/null
kc label ns kagent topology.istio.io/network="$CLUSTER_NAME" --overwrite >/dev/null
ok "kagent namespace is ambient (network=$CLUSTER_NAME)"

cat >&2 <<EOF

══════════════════════════════════════════════════════════════════
  Waypoint data plane ready.
══════════════════════════════════════════════════════════════════
  Next (per demo): ./scripts/accesspolicy-on.sh
    - labels the MCP server kagent.solo.io/waypoint=true
    - applies an AccessPolicy that DENIES the printenv tool
    - the agent's tool list then drops printenv
EOF

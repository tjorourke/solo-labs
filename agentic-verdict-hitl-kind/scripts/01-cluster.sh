#!/usr/bin/env bash
# 01-cluster.sh — kind cluster + a host-side local OCI registry on :5001 +
# MetalLB + Gateway API CRDs.
#
# The local registry is what `arctl build --push` pushes the two agent images to
# and what the kagent pods pull from (the scaffolds default to
# localhost:5001/...). Registry wiring follows the canonical kind recipe:
# https://kind.sigs.k8s.io/docs/user/local-registry/
#
# MetalLB gives the agentgateway ingress a real LoadBalancer IP, which the lab
# turns into *.<LB-IP>.sslip.io hostnames. That avoids fighting another kind
# cluster for host :80.
#
# Idempotent: skips cluster creation if it exists; every apply is re-runnable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Pre-flight"
require kind; require kubectl; require helm; require docker; require curl
require jq; require arctl; require openssl
check_docker
ok "tools + docker reachable"

# ── local OCI registry ────────────────────────────────────────────────────────
step "Local registry container '$REG_NAME' on :$REG_PORT"
if [[ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null)" == "true" ]]; then
  ok "registry '$REG_NAME' already running"
else
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" \
    --name "$REG_NAME" registry:2 >/dev/null
  ok "registry '$REG_NAME' started"
fi

# ── kind cluster ──────────────────────────────────────────────────────────────
step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster '$CLUSTER_NAME' already exists — skipping"
else
  kind create cluster --config "$LAB_ROOT/kind/cluster.yaml"
  ok "cluster '$CLUSTER_NAME' created"
fi

step "Wiring nodes to the local registry"
# Per-node hosts.toml so containerd resolves localhost:5001 -> kind-registry:5000.
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" mkdir -p "$REGISTRY_DIR"
  cat <<EOF | docker exec -i "$node" cp /dev/stdin "$REGISTRY_DIR/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
done
# Join the registry to the kind docker network so nodes can reach it by name.
if [[ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REG_NAME" 2>/dev/null)" == "null" ]]; then
  docker network connect kind "$REG_NAME" >/dev/null 2>&1 || true
fi
ok "nodes point localhost:${REG_PORT} -> ${REG_NAME}:5000"

kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
ok "local-registry-hosting advertised to the cluster"

# ── MetalLB ───────────────────────────────────────────────────────────────────
step "Installing MetalLB $METALLB_VERSION"
kc apply -f \
  "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
  >/dev/null
ok "MetalLB manifests applied"

log "waiting for the MetalLB controller..."
kc -n metallb-system wait \
  --for=condition=Ready pod -l app=metallb,component=controller --timeout=180s >/dev/null
ok "MetalLB controller ready"

# Hand out a small slice of the kind docker network as LoadBalancer IPs.
#
# The prefix has to come from the actual mask, not a guess. A kind network can be
# a /16 (172.18.0.0/16) or a /24 (192.168.97.0/24), and assuming /16 on a /24
# network produces a pool OUTSIDE the subnet — MetalLB assigns an address the host
# can never route to, and the Gateway sits Programmed with an unreachable IP.
KIND_CIDR="$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1)"
[[ -n "$KIND_CIDR" ]] || die "kind docker network not found"
KIND_MASK="${KIND_CIDR##*/}"
if (( KIND_MASK >= 24 )); then
  # /24 or narrower: the third octet is fixed by the subnet.
  PREFIX="$(echo "${KIND_CIDR%%/*}" | cut -d. -f1-3)"
else
  # Wider than /24: pick a high third octet inside the range.
  PREFIX="$(echo "${KIND_CIDR%%/*}" | cut -d. -f1,2).255"
fi

# Other kind clusters commonly share this docker network and have their own pools
# (the istio-ambient-demo-kind clusters take .140-.150 and .160-.170). Overlapping
# pools mean two clusters hand out the same IP and traffic lands on whichever ARPs
# last, which looks like random gateway failures. Default well clear of those, and
# allow an override.
LB_START="${LB_POOL_START:-${PREFIX}.180}"
LB_END="${LB_POOL_END:-${PREFIX}.190}"
log "kind network: $KIND_CIDR  (pool prefix: $PREFIX)"

# Warn on a real overlap rather than failing: the other cluster may be stopped.
for other in $(kind get clusters 2>/dev/null | grep -vx "$CLUSTER_NAME"); do
  existing="$(kubectl --context "kind-${other}" get ipaddresspool -A \
    -o jsonpath='{range .items[*]}{.spec.addresses[*]}{" "}{end}' 2>/dev/null || true)"
  [[ -n "$existing" ]] && log "cluster '$other' holds: $existing"
  case "$existing" in
    *"${LB_START}"*|*"${LB_END}"*)
      warn "pool ${LB_START}-${LB_END} overlaps cluster '$other' — set LB_POOL_START/LB_POOL_END" ;;
  esac
done

kc apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${LB_START}-${LB_END}"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
ok "MetalLB pool: ${LB_START}-${LB_END}"

# ── Gateway API CRDs ──────────────────────────────────────────────────────────
step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kc apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  >/dev/null
ok "Gateway API CRDs applied"

# ── namespaces ────────────────────────────────────────────────────────────────
step "Creating namespaces"
kc apply -f "$LAB_ROOT/yaml/namespaces/00-namespaces.yaml" >/dev/null
ok "namespaces created"

step "Cluster ready"
echo "  Context: $CTX" >&2
echo "  Next:    ./scripts/02-agentgateway.sh" >&2

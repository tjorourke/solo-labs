#!/usr/bin/env bash
# End-to-end VM test using istioctl bootstrap (no token patching required).
# Creates vm2, generates BOOTSTRAP_TOKEN, runs mock Docker VM, starts ztunnel,
# and verifies the ztunnel↔istiod connection.
#
# Prerequisites: clusters up, Istio installed, MetalLB pools applied.
# Usage: CLUSTER1=kind-east ./scripts/test-vm-e2e.sh

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER1="${CLUSTER1:-kind-east}"
VM_NAME="vm2"
VM_NS="vm2"
ZTUNNEL_IMAGE="us-docker.pkg.dev/soloio-img/istio/ztunnel:1.29.0-solo-distroless"

log()    { echo "  → $*"; }
log_ok() { echo "  ✓ $*"; }
die()    { echo ""; echo "ERROR: $*" >&2; exit 1; }

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  VM E2E Test — ${VM_NAME} on ${CLUSTER1}"
echo "══════════════════════════════════════════════════════════"
echo ""

# ── 1. Solo istioctl ─────────────────────────────────────────────────────────
export PATH="${HOME}/.istioctl/bin:${PATH}"
istioctl bootstrap --help >/dev/null 2>&1 || \
  die "istioctl bootstrap not found — need Solo's binary at ~/.istioctl/bin/istioctl"
ISTIO_VER=$(istioctl version --remote=false 2>/dev/null | grep -o 'version:[^,]*' | head -1 || echo "unknown")
log_ok "istioctl bootstrap available (${ISTIO_VER})"

# ── 2. MetalLB IP ────────────────────────────────────────────────────────────
log "checking MetalLB IP on ${CLUSTER1}..."
ISTIOD_IP=$(kubectl --context="${CLUSTER1}" get svc -A \
  -l istio.io/expose-istiod \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[[ -n "$ISTIOD_IP" ]] || \
  die "no MetalLB IP on istiod LB service — run scripts/02-metallb.sh and wait for Istio to install the east-west GW"
log_ok "istiod LoadBalancer IP: ${ISTIOD_IP}"

# ── 3. Namespace + SA ────────────────────────────────────────────────────────
log "creating namespace ${VM_NS}..."
kubectl --context="${CLUSTER1}" get ns "${VM_NS}" >/dev/null 2>&1 && \
  kubectl --context="${CLUSTER1}" delete ns "${VM_NS}" --wait=true --timeout=30s 2>/dev/null || true
kubectl --context="${CLUSTER1}" create namespace "${VM_NS}"
kubectl --context="${CLUSTER1}" create serviceaccount "${VM_NAME}" -n "${VM_NS}"
log_ok "namespace ${VM_NS} and SA ${VM_NAME} created"

# ── 4. BOOTSTRAP_TOKEN ───────────────────────────────────────────────────────
log "generating BOOTSTRAP_TOKEN..."
BOOTSTRAP_TOKEN=$(istioctl --context="${CLUSTER1}" \
  bootstrap --namespace "${VM_NS}" --service-account "${VM_NAME}" 2>/dev/null)
[[ -n "$BOOTSTRAP_TOKEN" ]] || die "BOOTSTRAP_TOKEN is empty"

# Verify the embedded URL
EMBEDDED_URL=$(echo "${BOOTSTRAP_TOKEN}" | base64 -d | base64 -d | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
log_ok "BOOTSTRAP_TOKEN generated — url: ${EMBEDDED_URL}"

if ! echo "${EMBEDDED_URL}" | grep -q "${ISTIOD_IP}"; then
  echo "  WARNING: embedded URL ${EMBEDDED_URL} doesn't match expected MetalLB IP ${ISTIOD_IP}"
fi

# Patch: istioctl bootstrap embeds an SA Secret token with audience
# "kubernetes.default.svc.cluster.local" but istiod XDS auth requires "istio-ca".
log "patching BOOTSTRAP_TOKEN (replacing inner token with audience: istio-ca)..."
export NEW_TOKEN
NEW_TOKEN=$(kubectl --context="${CLUSTER1}" create token "${VM_NAME}" \
  -n "${VM_NS}" --audience istio-ca --duration 24h)
BOOTSTRAP_TOKEN=$(echo "${BOOTSTRAP_TOKEN}" | base64 -d | base64 -d | python3 -c "
import sys, json, base64, os
envelope = json.load(sys.stdin)
envelope['token'] = os.environ['NEW_TOKEN']
raw = json.dumps(envelope)
print(base64.b64encode(base64.b64encode(raw.encode()).decode().encode()).decode())
")
log_ok "token patched (24h TTL, audience: istio-ca)"

# ── 5. Build mock VM image ───────────────────────────────────────────────────
if docker image inspect vm-with-docker >/dev/null 2>&1; then
  log_ok "vm-with-docker image already built"
else
  log "building vm-with-docker image (first time only, ~2 min)..."
  docker build -t vm-with-docker -f "${REPO_ROOT}/Dockerfile.vm" "${REPO_ROOT}" 2>&1 | \
    grep -v '^#' | grep -v '^$' | sed 's/^/    /' | tail -5
  log_ok "vm-with-docker image built"
fi

# ── 6. Start mock VM container ───────────────────────────────────────────────
docker rm -f "${VM_NAME}" 2>/dev/null || true
docker run -d \
  --name "${VM_NAME}" \
  --network kind \
  --privileged \
  --hostname "${VM_NAME}" \
  vm-with-docker \
  sh -c "dockerd --storage-driver=vfs > /var/log/dockerd.log 2>&1 & sleep infinity"
VM_IP=$(docker inspect "${VM_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
log_ok "VM container ${VM_NAME} started — IP: ${VM_IP}"

# ── 7. Wait for dockerd ──────────────────────────────────────────────────────
log "waiting for dockerd inside VM..."
for i in $(seq 1 30); do
  docker exec "${VM_NAME}" docker info >/dev/null 2>&1 && break
  sleep 2
  [[ $i -lt 30 ]] || die "dockerd did not start in time — check: docker exec ${VM_NAME} cat /var/log/dockerd.log"
done
log_ok "dockerd ready"

# ── 8. Start ztunnel ─────────────────────────────────────────────────────────
log "pulling ztunnel image inside VM (may take a minute)..."
docker exec "${VM_NAME}" docker pull "${ZTUNNEL_IMAGE}" 2>&1 | tail -2 | sed 's/^/    /'

log "starting ztunnel inside VM..."
docker exec "${VM_NAME}" docker run -d \
  --name ztunnel \
  --network host \
  --privileged \
  -e "BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}" \
  -e ALWAYS_TRAVERSE_NETWORK_GATEWAY=true \
  "${ZTUNNEL_IMAGE}"
log_ok "ztunnel container started"

# ── 9. Wait for istiod connection ────────────────────────────────────────────
log "waiting for ztunnel to connect to istiod..."
for i in $(seq 1 45); do
  ZTUNNEL_LOG=$(docker exec "${VM_NAME}" docker logs ztunnel 2>&1 || true)
  if echo "${ZTUNNEL_LOG}" | grep -qE "Stream established|marking server ready|state manager.*complete"; then
    log_ok "ztunnel connected to istiod"
    break
  fi
  if echo "${ZTUNNEL_LOG}" | grep -q "Unauthenticated\|authentication failure"; then
    echo ""
    echo "  ztunnel auth error:"
    echo "${ZTUNNEL_LOG}" | grep -i "Unauthenticated\|authentication" | head -3 | sed 's/^/    /'
    die "ztunnel authentication failed — check BOOTSTRAP_TOKEN and istiod logs"
  fi
  sleep 2
  [[ $i -lt 45 ]] || {
    echo "  Last ztunnel logs:"
    echo "${ZTUNNEL_LOG}" | tail -15 | sed 's/^/    /'
    die "ztunnel did not connect within 90s"
  }
done

# ── 10. Verify via k8s side ──────────────────────────────────────────────────
log "checking ztunnel registration on ${CLUSTER1}..."
sleep 3
ZTUNNEL_MESH=$(kubectl --context="${CLUSTER1}" -n istio-system logs ds/ztunnel 2>/dev/null | \
  grep -i "${VM_IP}\|${VM_NS}\|${VM_NAME}" | tail -3 || true)
if [[ -n "${ZTUNNEL_MESH}" ]]; then
  log_ok "VM seen in mesh ztunnel logs:"
  echo "${ZTUNNEL_MESH}" | sed 's/^/    /'
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  PASS — ${VM_NAME} connected to mesh via istioctl bootstrap"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  VM IP:              ${VM_IP}"
echo "  istiod URL:         ${EMBEDDED_URL}"
echo "  Bootstrap token:    generated by istioctl bootstrap + patched (audience: istio-ca)"
echo ""
echo "  Test mesh access from inside VM:"
echo "    docker exec -it ${VM_NAME} bash"
echo "    ALL_PROXY=socks5h://127.0.0.1:15080 curl productpage.bookinfo:9080/productpage"
echo ""
echo "  View ztunnel logs:  docker exec ${VM_NAME} docker logs ztunnel"
echo "  Cleanup:            docker rm -f ${VM_NAME}"
echo "                      kubectl --context=${CLUSTER1} delete ns ${VM_NS}"
echo ""

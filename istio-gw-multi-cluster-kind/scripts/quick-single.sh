#!/usr/bin/env bash
# quick-single.sh — stand up ONE Solo Enterprise Istio Ambient kind cluster on
# this host. Intended for the "east on a laptop, west on a mac mini, then peer
# across the real network" demo flow.
#
# Differs from quick.sh:
#   * Builds exactly ONE cluster (free-form name supplied by the user).
#   * Skips every cross-cluster step (`istioctl multicluster expose` against
#     the peer, remote-secret cross-apply, the "remote cluster" log probe)
#     because the other cluster lives on a different host.
#   * Reuses certs/root-ca.{crt,key} when present, so the SAME root CA can be
#     copied between machines (cross-cluster mTLS requires identical roots).
#   * At the end, writes certs/peer-bundle-<name>.tar.gz and prints the
#     copy-paste commands the operator runs on the OTHER machine to consume it.
#
# Usage:
#   ./scripts/quick-single.sh <cluster-name>          # stand up
#   ./scripts/quick-single.sh teardown <cluster-name> # tear down + remove certs/
#
# Examples (cluster name is free-form; anything matching a k8s DNS label):
#   ./scripts/quick-single.sh green
#   ./scripts/quick-single.sh east-laptop
#   ./scripts/quick-single.sh west-mini

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-/Users/tomorourke/code/solo/secrets/secrets-envs.sh}"

GLOO_OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.3-solo}"
ISTIO_VERSION_OPERATOR="${SOLO_ISTIO_VERSION%-solo}"   # 1.29.2 — for SMC .spec.version
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
ISTIO_TAG="${SOLO_ISTIO_VERSION}"                       # 1.29.2-solo — image tags include -solo
CERTS_DIR="$REPO_ROOT/certs"

# ── Utilities ─────────────────────────────────────────────────────────────────

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "══> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

YEL=$'\033[33m'
RST=$'\033[0m'

validate_name() {
  local n="$1"
  [[ -n "$n" ]] || die "cluster name required. Example: ./scripts/quick-single.sh green"
  if [[ ! "$n" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
    cat >&2 <<EOF
ERROR: '$n' is not a valid cluster name.

  Requirements (Kubernetes DNS label):
    * lowercase letters, digits, '-'
    * must start with a letter
    * must end with a letter or digit
    * length 2-63

  Examples: green  blue  east-laptop  west-mini  north
EOF
    exit 1
  fi
}

wait_deploy() {
  local ctx="$1" ns="$2" name="$3" timeout="${4:-300s}"
  local secs="${timeout%s}"
  local end=$(( $(date +%s) + secs ))
  until kubectl --context "$ctx" -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    if [[ $(date +%s) -ge $end ]]; then
      echo "  ERROR: deployment $ns/$name not created within $timeout" >&2
      return 1
    fi
    sleep 3
  done
  kubectl --context "$ctx" -n "$ns" wait \
    --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

# ── Teardown ──────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "teardown" ]]; then
  NAME="${2:-}"
  validate_name "$NAME"
  step "Tearing down single-cluster setup ($NAME)"
  kind delete cluster --name "$NAME" 2>/dev/null && log_ok "$NAME deleted" || true
  rm -rf "$CERTS_DIR" && log_ok "certs/ removed" || true
  echo ""; echo "Done."; exit 0
fi

NAME="${1:-}"
validate_name "$NAME"
CTX="kind-${NAME}"

# ── Secrets ───────────────────────────────────────────────────────────────────

[[ -f "$SECRETS_FILE" ]] && { set -a; source "$SECRETS_FILE"; set +a; }
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || die "SOLO_ISTIO_LICENSE_KEY not set (source secrets-envs.sh or export it)"

# ── Up-front warning about the root CA ───────────────────────────────────────

if [[ ! -f "$CERTS_DIR/root-ca.crt" ]]; then
  cat <<EOF
${YEL}NOTE — multi-machine peering:${RST}
  If this is the SECOND machine in the peering setup, STOP NOW and copy
  certs/root-ca.crt + certs/root-ca.key from the FIRST machine into
  $CERTS_DIR/ before continuing. The two clusters must share the same
  root CA, otherwise cross-cluster mTLS will fail.

  If this is the FIRST (or only) machine, ignore this note — a fresh root
  CA will be generated.

EOF
fi

# ── Prereqs ───────────────────────────────────────────────────────────────────

step "Checking prereqs"
require kind; require kubectl; require helm; require docker; require openssl; require istioctl
log_ok "all tools present"

if ! docker info >/dev/null 2>&1; then
  cat >&2 <<EOF

ERROR: docker daemon is not reachable.

  Tried: docker info → failed
EOF
  case "$(uname -s)" in
    Darwin) cat >&2 <<EOF
  Likely cause on macOS: Docker Desktop / OrbStack isn't running, OR you're
  SSHed into a Mac whose GUI session is locked. Docker Desktop only publishes
  its socket while the GUI is unlocked — SSH sessions can't start it.

  Fix:
    1. Physically unlock the Mac (or unlock via remote desktop).
    2. open -a Docker      (or: open -a OrbStack).
    3. Re-run this script.

EOF
      ;;
    Linux) cat >&2 <<EOF
  Likely cause on Linux: docker daemon isn't running, or your user isn't in
  the docker group (so the socket exists but you can't talk to it).

  Fix:
    sudo systemctl start docker
    sudo usermod -aG docker "\$USER"   # then log out + back in
    Re-run this script.

EOF
      ;;
    *) echo "  Start your docker daemon and re-run." >&2 ;;
  esac
  exit 1
fi
log_ok "docker daemon reachable"

# Verify docker can actually pull from a public registry. On macOS this is a
# real check, not pedantry: docker stores registry creds in the login keychain,
# and SSH sessions can't interactively unlock it. Without this guard the script
# crashes inside 'kind create' with a keychain error and a partial cluster.
#
# If the first pull fails on macOS and we have a real TTY, offer to unlock
# the login keychain inline (security will prompt for the password) then
# retry, so the user doesn't have to copy/paste a command and re-run.
keychain_unlock_and_retry() {
  [[ "$(uname)" == "Darwin" ]] || return 1
  [[ -t 0 ]] || return 1   # need a real TTY for the password prompt
  echo ""
  echo "  Login keychain is likely locked — docker can't read its registry creds."
  echo "  Unlocking it now (Mac login password prompt will follow)."
  echo "  Ctrl-C to skip and fix manually."
  echo ""
  security -v unlock-keychain "$HOME/Library/Keychains/login.keychain-db" </dev/tty || return 1
  docker pull --quiet hello-world:latest >/dev/null 2>&1
}

if ! docker pull --quiet hello-world:latest >/dev/null 2>&1; then
  if ! keychain_unlock_and_retry; then
    cat >&2 <<EOF

ERROR: docker can't pull from a public registry.

  Tried: docker pull hello-world:latest → failed
  Most common cause on macOS over SSH: the login keychain is locked, so
  the docker credential helper can't read registry credentials.

  Manual fix (one-shot for this SSH session):
    security -v unlock-keychain \$HOME/Library/Keychains/login.keychain-db
    # enter your Mac login password when prompted; then re-run this script.

  Permanent workaround (avoid credential helper entirely):
    Edit ~/.docker/config.json and remove the "credsStore" key.
    Anonymous pulls work without credentials, which is all kind needs.

EOF
    exit 1
  fi
fi
log_ok "docker can pull from public registry"

# ── Step 1: kind cluster ─────────────────────────────────────────────────────
# No CIDR partitioning needed: each machine has its own Docker bridge, and
# cross-cluster traffic egresses via the east-west GW's external LB IP (HBONE),
# never pod-IP to pod-IP. Both halves of the peering can safely use the same
# pod/service CIDRs.

step "Creating kind cluster ($NAME)"
if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  log "[$NAME] already exists — skipping"
else
  log "[$NAME] creating..."
  kind create cluster --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $NAME
networking:
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
  - role: worker
EOF
  log_ok "[$NAME] ready"
fi

# ── Step 2: MetalLB ───────────────────────────────────────────────────────────

step "Installing MetalLB $METALLB_VERSION"
KIND_CIDR="$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1)"
[[ -n "$KIND_CIDR" ]] || die "kind Docker network not found — cluster must be up first"
BASE="$(echo "$KIND_CIDR" | cut -d. -f1,2)"
log "kind network: $KIND_CIDR  (base: $BASE)"

kubectl --context "$CTX" apply -f \
  "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
  >/dev/null
kubectl --context "$CTX" -n metallb-system wait \
  --for=condition=Ready pod -l app=metallb,component=controller --timeout=90s >/dev/null
log_ok "[$NAME] MetalLB controller ready"

# Single-cluster setup, no partitioning required. Use east's range (.200-.210).
kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.255.200-${BASE}.255.210"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
log_ok "MetalLB pool configured  ($NAME .200-.210)"

# ── Step 3: Shared root CA + this cluster's intermediate ──────────────────────

step "Generating / reusing root CA + this cluster's intermediate"
mkdir -p "$CERTS_DIR"

if [[ ! -f "$CERTS_DIR/root-ca.crt" ]]; then
  openssl genrsa -out "$CERTS_DIR/root-ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 \
    -key "$CERTS_DIR/root-ca.key" \
    -subj "/O=Solo Demo/CN=Shared Root CA" \
    -out "$CERTS_DIR/root-ca.crt" 2>/dev/null
  log_ok "root CA generated (NEW — copy to the other machine before standing it up)"
else
  log_ok "root CA reused from $CERTS_DIR/root-ca.crt"
fi

if [[ ! -f "$CERTS_DIR/${NAME}-ca.crt" ]]; then
  openssl genrsa -out "$CERTS_DIR/${NAME}-ca.key" 4096 2>/dev/null
  cat > "$CERTS_DIR/${NAME}-csr.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt = no
[req_distinguished_name]
O  = Solo Demo
CN = ${NAME} Intermediate CA
[v3_req]
subjectAltName = URI:spiffe://cluster.local/ns/istio-system/sa/citadel
basicConstraints = CA:TRUE
keyUsage = keyCertSign, cRLSign
EOF
  openssl req -new \
    -key "$CERTS_DIR/${NAME}-ca.key" \
    -config "$CERTS_DIR/${NAME}-csr.conf" \
    -out "$CERTS_DIR/${NAME}-ca.csr" 2>/dev/null
  openssl x509 -req -days 3650 \
    -in  "$CERTS_DIR/${NAME}-ca.csr" \
    -CA  "$CERTS_DIR/root-ca.crt" -CAkey "$CERTS_DIR/root-ca.key" \
    -CAcreateserial \
    -extfile "$CERTS_DIR/${NAME}-csr.conf" -extensions v3_req \
    -out "$CERTS_DIR/${NAME}-ca.crt" 2>/dev/null
  log_ok "[$NAME] intermediate CA generated"
fi

cat "$CERTS_DIR/${NAME}-ca.crt" "$CERTS_DIR/root-ca.crt" > "$CERTS_DIR/${NAME}-ca-chain.crt"
kubectl --context "$CTX" create namespace istio-system 2>/dev/null || true
kubectl --context "$CTX" create namespace istio-gateways 2>/dev/null || true
kubectl --context "$CTX" -n istio-system create secret generic cacerts \
  --from-file=ca-cert.pem="$CERTS_DIR/${NAME}-ca.crt" \
  --from-file=ca-key.pem="$CERTS_DIR/${NAME}-ca.key" \
  --from-file=root-cert.pem="$CERTS_DIR/root-ca.crt" \
  --from-file=cert-chain.pem="$CERTS_DIR/${NAME}-ca-chain.crt" \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
log_ok "[$NAME] cacerts secret applied"

# ── Step 5: Gateway API CRDs ──────────────────────────────────────────────────

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kubectl --context "$CTX" apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  >/dev/null
log_ok "[$NAME] Gateway API CRDs applied"

# ── Step 6: Pre-pull Solo Istio images ────────────────────────────────────────

step "Pre-pulling Solo Istio images ($ISTIO_TAG)"
KIND_PLATFORM="linux/$(docker info --format '{{.Architecture}}' | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
log "kind node platform: $KIND_PLATFORM"
for IMG in pilot proxyv2 install-cni ztunnel; do
  FULL="${ISTIO_REGISTRY}/${IMG}:${ISTIO_TAG}"
  if docker image inspect "$FULL" >/dev/null 2>&1; then
    log_ok "cached: $IMG"
  else
    log "pulling $IMG..."
    docker pull --quiet --platform "$KIND_PLATFORM" "$FULL"
    log_ok "$IMG pulled"
  fi
done

# Bypass `kind load docker-image` (--all-platforms fails on Apple Silicon for
# multi-arch manifests). Pipe `docker save` directly into `ctr import -`.
loaded=0; skipped=0
for ROLE in control-plane worker; do
  NODE="${NAME}-${ROLE}"
  for IMG in pilot proxyv2 install-cni ztunnel; do
    REF="${ISTIO_REGISTRY}/${IMG}:${ISTIO_TAG}"
    if docker exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null \
         | grep -qx "$REF"; then
      skipped=$((skipped+1))
      continue
    fi
    docker save "$REF" \
      | docker exec --privileged -i "$NODE" ctr -n k8s.io images import - \
        >/dev/null
  loaded=$((loaded+1))
  done
done
log_ok "[$NAME] images loaded: $loaded new, $skipped already present"

# ── Step 7: Gloo Operator + Solo Istio ───────────────────────────────────────

step "Installing Gloo Operator $GLOO_OPERATOR_VERSION"
helm upgrade --install gloo-operator \
  oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator \
  --kube-context "$CTX" \
  --namespace gloo-system --create-namespace \
  --version "$GLOO_OPERATOR_VERSION" \
  --set manager.env.SOLO_ISTIO_LICENSE_KEY="${SOLO_ISTIO_LICENSE_KEY}" \
  --wait >/dev/null
log_ok "[$NAME] Gloo Operator ready"

step "Applying ServiceMeshController CR"
kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
  namespace: gloo-system
spec:
  cluster: ${NAME}
  network: ${NAME}
  trustDomain: cluster.local
  version: "${ISTIO_VERSION_OPERATOR}"
  dataplaneMode: Ambient
  distribution: Standard
  scalingProfile: Demo
EOF
log_ok "[$NAME] SMC applied"

step "Waiting for istiod-gloo"
wait_deploy "$CTX" istio-system istiod-gloo 300s
log_ok "[$NAME] istiod-gloo ready"

step "Creating solo-istio-license secret in istio-system"
kubectl --context "$CTX" -n istio-system create secret generic solo-istio-license \
  --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
log_ok "[$NAME] license secret applied"

step "Patching istiod env vars + SOLO_LICENSE_KEY"
# Idempotency: only patch if the env var isn't already set.
patch_env_once() {
  local ctx="$1" kind_="$2" name_="$3" var="$4" patch_json="$5"
  if kubectl --context "$ctx" -n istio-system get "$kind_" "$name_" \
       -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${var}')].name}" \
       2>/dev/null | grep -qx "$var"; then
    return 0
  fi
  kubectl --context "$ctx" -n istio-system patch "$kind_" "$name_" \
    --type=json -p="$patch_json" >/dev/null
}

patch_env_once "$CTX" deployment istiod-gloo PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES \
  '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES","value":"false"}}]'
patch_env_once "$CTX" deployment istiod-gloo SOLO_LICENSE_KEY \
  '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"SOLO_LICENSE_KEY","valueFrom":{"secretKeyRef":{"name":"solo-istio-license","key":"license"}}}}]'
log_ok "[$NAME] istiod env patched"

step "Patching ztunnel L7_ENABLED"
end=$(( $(date +%s) + 120 ))
until kubectl --context "$CTX" -n istio-system get daemonset ztunnel >/dev/null 2>&1; do
  [[ $(date +%s) -ge $end ]] && die "ztunnel DaemonSet not created in 2m"
  sleep 3
done
patch_env_once "$CTX" daemonset ztunnel L7_ENABLED \
  '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"L7_ENABLED","value":"true"}}]'
log_ok "[$NAME] ztunnel env patched"

kubectl --context "$CTX" -n istio-system rollout status deployment/istiod-gloo --timeout=120s >/dev/null
kubectl --context "$CTX" -n istio-system rollout status daemonset/ztunnel --timeout=120s >/dev/null
log_ok "istiod-gloo + ztunnel rollout complete"

# ── Step 8: Expose this cluster's east-west gateway ──────────────────────────
# `istioctl multicluster expose` is idempotent: it creates the east-west GW in
# istio-gateways and emits a remote-secret YAML on stdout (the kubeconfig that
# the PEER cluster will apply so its istiod can discover Services on THIS one).
# In the two-cluster quick.sh we pipe that into the other cluster directly; in
# the single-cluster flow we capture it into the peer bundle for shipping.

step "Waiting for istiod pod to be Running"
kubectl --context "$CTX" -n istio-system wait \
  --for=condition=Ready pod -l app=istiod --timeout=120s >/dev/null

step "Exposing cluster east-west via istioctl"
REMOTE_SECRET_YAML="$(istioctl --context "$CTX" multicluster expose -n istio-gateways 2>/dev/null)"
[[ -n "$REMOTE_SECRET_YAML" ]] || die "istioctl multicluster expose produced no output"
log_ok "[$NAME] east-west gateway exposed"

step "Waiting for east-west gateway LB IP"
EW_IP=""
for i in $(seq 1 40); do
  EW_IP="$(kubectl --context "$CTX" -n istio-gateways \
    get svc istio-eastwest -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$EW_IP" ]] && break
  sleep 3
done
[[ -n "$EW_IP" ]] || die "east-west LB IP not assigned — check MetalLB pool capacity"
log_ok "[$NAME] east-west IP: $EW_IP"

# ── Step 9: Label istio-system with network topology ─────────────────────────

step "Labelling istio-system with network topology"
kubectl --context "$CTX" label namespace istio-system \
  topology.istio.io/network="$NAME" --overwrite >/dev/null
log_ok "[$NAME] istio-system labelled network=$NAME"

# ── Platform smoke test ──────────────────────────────────────────────────────

step "Smoke test — platform health"
fail=0
if ! kubectl --context "$CTX" -n istio-system get deploy istiod-gloo \
     -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null \
     | grep -qx True; then
  log "  ✗ [$NAME] istiod-gloo not Available"; fail=1
else
  log_ok "[$NAME] istiod-gloo Available"
fi

ready="$(kubectl --context "$CTX" -n istio-system get ds ztunnel \
          -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"
if [[ "$ready" =~ ^[1-9][0-9]*/([1-9][0-9]*)$ ]] && [[ "${ready%/*}" == "${ready#*/}" ]]; then
  log_ok "[$NAME] ztunnel fully scheduled ($ready)"
else
  log "  · [$NAME] ztunnel: $ready"
fi

[[ -n "$EW_IP" ]] && log_ok "[$NAME] east-west gateway LB IP: $EW_IP" \
  || { log "  ✗ [$NAME] east-west gateway has no LB IP"; fail=1; }

if [[ $fail -eq 0 ]]; then
  log_ok "Platform smoke test: PASS"
else
  log "Platform smoke test: FAIL — see logs above"
fi

# ── Peering bundle for the OTHER machine ─────────────────────────────────────
# The other machine needs:
#   1. our root-ca.crt + root-ca.key (so its intermediate CA chains back to the
#      SAME root — required for cross-cluster mTLS).
#   2. our istio-remote-secret-<NAME> kubeconfig Secret (the YAML emitted by
#      `istioctl multicluster expose` above) — its istiod-gloo applies this
#      to discover our k8s API and Services.
#   3. our east-west GW external LB IP + cluster/network name (so its peering
#      points back at us).

step "Building peering bundle for the other machine"
BUNDLE_DIR="$CERTS_DIR/peer-bundle-${NAME}"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

printf '%s\n' "$REMOTE_SECRET_YAML" > "$BUNDLE_DIR/istio-remote-secret-${NAME}.yaml"
echo -n "$EW_IP" > "$BUNDLE_DIR/eastwest-ip.txt"
echo -n "$NAME"  > "$BUNDLE_DIR/cluster-name.txt"
cp "$CERTS_DIR/root-ca.crt" "$BUNDLE_DIR/root-ca.crt"
cp "$CERTS_DIR/root-ca.key" "$BUNDLE_DIR/root-ca.key"

BUNDLE_TGZ="$CERTS_DIR/peer-bundle-${NAME}.tar.gz"
tar -C "$CERTS_DIR" -czf "$BUNDLE_TGZ" "peer-bundle-${NAME}"
log_ok "wrote $BUNDLE_TGZ"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Solo Enterprise Istio Ambient — single-cluster standup"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Cluster:        $CTX"
echo "  Network:        $NAME"
echo "  Solo Istio:     $SOLO_ISTIO_VERSION"
echo "  East-west IP:   $EW_IP"
echo ""
echo "  Teardown:"
echo "    ./scripts/quick-single.sh teardown $NAME"
echo ""
echo "${YEL}────────────────────────────────────────────────────────────────────${RST}"
echo "${YEL}  Peer with the OTHER machine${RST}"
echo "${YEL}────────────────────────────────────────────────────────────────────${RST}"
echo ""
echo "  1. Copy this peering bundle from THIS machine to the OTHER machine:"
echo ""
echo "       scp $BUNDLE_TGZ user@other-host:/tmp/"
echo ""
echo "  2. On the OTHER machine, BEFORE running its own quick-single.sh,"
echo "     drop the shared root CA into its certs/ so its intermediate"
echo "     chains back to the same root:"
echo ""
echo "       mkdir -p certs && \\"
echo "         tar -xzf /tmp/peer-bundle-${NAME}.tar.gz -C /tmp && \\"
echo "         cp /tmp/peer-bundle-${NAME}/root-ca.crt certs/ && \\"
echo "         cp /tmp/peer-bundle-${NAME}/root-ca.key certs/"
echo ""
echo "  3. Stand up the OTHER cluster (free-form name, e.g. 'west-mini'):"
echo ""
echo "       ./scripts/quick-single.sh west-mini"
echo ""
echo "  4. Once the OTHER cluster is up, finish the peering on it by"
echo "     consuming the bundle from THIS machine. The remote-secret"
echo "     captured here is exactly the YAML that 'istioctl multicluster"
echo "     expose' would have piped into the peer in the same-host setup:"
echo ""
echo "       OTHER_CTX=kind-west-mini   # whatever you named the other cluster"
echo "       kubectl --context \$OTHER_CTX apply \\"
echo "         -f /tmp/peer-bundle-${NAME}/istio-remote-secret-${NAME}.yaml"
echo ""
echo "  5. Do the SYMMETRIC step from the other direction: ship the OTHER"
echo "     machine's peer-bundle-<name>.tar.gz back to THIS machine and run"
echo "     the equivalent kubectl apply here, substituting THIS context"
echo "     ($CTX) for OTHER_CTX."
echo ""
echo "  6. Verify on either side (should report both clusters connected):"
echo ""
echo "       istioctl --context $CTX multicluster check"
echo "       kubectl --context $CTX -n istio-system logs deploy/istiod-gloo \\"
echo "         | grep 'remote cluster'"
echo ""
echo "${YEL}  Networking caveat:${RST} the OTHER machine must be able to reach"
echo "  THIS machine's east-west IP ($EW_IP) on TCP 15008 + 15012 + 15021."
echo "  With kind on macOS, $EW_IP is a Docker-bridge address that's NOT"
echo "  routable from another host. For a real cross-host demo you need to"
echo "  either:"
echo "    * run on Linux with a routable bridge / host-network, or"
echo "    * front the east-west Service with a port-forward / tunnel that"
echo "      publishes the gateway ports on the host's LAN IP, then"
echo "      hand-edit the peer-bundle's istio-remote-secret YAML to point"
echo "      at that LAN IP instead of the in-cluster API server."
echo ""
echo "${YEL}────────────────────────────────────────────────────────────────────${RST}"
echo "${YEL}  Helper scripts for the cross-host networking step${RST}"
echo "${YEL}────────────────────────────────────────────────────────────────────${RST}"
echo ""
echo "  Two helpers automate the LAN tunnel + remote-secret rewrite:"
echo ""
echo "    ./scripts/expose-ew-on-host.sh $NAME"
echo "        Launches alpine/socat Docker containers (on the kind bridge)"
echo "        that republish 15008 + 15012 + 15021 on this machine's LAN IP,"
echo "        so the peer can reach the east-west GW across the wire."
echo ""
echo "    ./scripts/peer-with.sh <local-name> <bundle.tar.gz> <peer-host:15008>"
echo "        Run on the OTHER machine after THIS one's peer bundle has been"
echo "        copied across. Verifies the shared root CA, rewrites the bundle's"
echo "        kubeconfig server URL to a LAN-reachable kube-API endpoint,"
echo "        applies the remote-secret, and creates the istio-remote Gateway"
echo "        CR that points the local data plane at the peer's east-west GW."
echo ""
echo "  Tear the LAN tunnels down with:"
echo "    ./scripts/expose-ew-on-host.sh down $NAME"
echo ""

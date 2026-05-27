#!/usr/bin/env bash
# quick-single.sh — stand up ONE Solo Enterprise agentgateway + Ambient kind
# cluster on this host. Intended for the "east on a laptop, west on a mac mini,
# then peer across the real network" demo flow.
#
# Differs from quick.sh:
#   * Builds exactly ONE cluster (free-form name supplied by the user).
#   * Skips every cross-cluster step (peer Gateway CR, remote-secret cross-apply,
#     peering verification) because the other cluster lives on a different host.
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

# Optional: point SECRETS_FILE at a shell script that exports SOLO_ISTIO_LICENSE_KEY
# and AGENTGATEWAY_LICENSE_KEY. If unset, the script expects those two env vars to
# already be exported in the calling shell.
SECRETS_FILE="${SECRETS_FILE:-}"

GLOO_OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.2-solo}"
ISTIO_VERSION_OPERATOR="${SOLO_ISTIO_VERSION%-solo}"
AGW_VERSION="${AGW_VERSION:-v2.3.3}"
AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
AGW_IMAGE_REGISTRY="${AGW_IMAGE_REGISTRY:-}"

# Flip to the verified-fixed nightly with one env var. v2.3.3 NACKs istiod's
# synthetic cross-cluster WorkloadEntry; the nightly below has the fix.
if [[ "${AGW_NIGHTLY:-false}" == "true" ]]; then
  AGW_REGISTRY="oci://us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev/charts"
  AGW_VERSION="v2026.5.0-beta.4-nightly-2026-05-15"
  AGW_IMAGE_REGISTRY="us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev"
fi
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
ISTIO_TAG="${SOLO_ISTIO_VERSION%-solo}"
CERTS_DIR="$REPO_ROOT/certs"

# ── Utilities ─────────────────────────────────────────────────────────────────

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "══> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ANSI yellow for the "share with the other machine" call-outs.
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
  # The operator may not have created the deployment yet; `kubectl wait` errors
  # immediately on a non-existent resource (NotFound), which would kill the
  # script under `set -e`. Poll for existence up to 2m, then wait Available.
  local end=$(( $(date +%s) + 120 ))
  until kubectl --context "$ctx" -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && {
      echo "  deployment $ns/$name not created within 2m" >&2
      return 1
    }
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

if [[ -n "$SECRETS_FILE" ]]; then
  [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
  set -a; source "$SECRETS_FILE"; set +a
fi

missing=()
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}"   ]] || missing+=("SOLO_ISTIO_LICENSE_KEY")
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || missing+=("AGENTGATEWAY_LICENSE_KEY")
if (( ${#missing[@]} > 0 )); then
  cat >&2 <<EOF
ERROR: required license env vars not set: ${missing[*]}

Solo enterprise license keys are required to install:
  - Solo Istio (via Gloo Operator)            → SOLO_ISTIO_LICENSE_KEY
  - Solo Enterprise agentgateway              → AGENTGATEWAY_LICENSE_KEY

Get a trial / eval licence from https://www.solo.io/free-trial/ then either:

  # option 1 — export in your current shell
  export SOLO_ISTIO_LICENSE_KEY=eyJ...
  export AGENTGATEWAY_LICENSE_KEY=eyJ...
  ./scripts/quick-single.sh $NAME

  # option 2 — point at a sourceable file that exports both
  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick-single.sh $NAME
EOF
  exit 1
fi

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

# Docker daemon must be reachable. On macOS over SSH, Docker Desktop's socket
# (~/.docker/run/docker.sock) only exists when the GUI session is unlocked —
# this is the most common failure mode for remote standups.
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

# Verify docker can pull from a public registry (keychain not locked).
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

# Single-cluster setup, no partitioning required. Use east's range (.100-.110).
kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.255.100-${BASE}.255.110"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
log_ok "MetalLB pool configured  ($NAME .100-.110)"

# ── Step 3: Shared root CA + this cluster's intermediate ──────────────────────
# Reuse root-ca.{crt,key} if already present so the SAME root CA can be copied
# between the two machines in the peering. Always (re)generate this cluster's
# intermediate from the root.

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

# Why we bypass `kind load image-archive`:
#   On Apple Silicon `kind load` runs `ctr import --all-platforms`, which fails
#   with "content digest <sha>: not found" because Docker pulled only the
#   arm64 layers from a multi-arch manifest. Pipe `docker save` directly into
#   `ctr import -` on each kind node — that imports just the host arch.
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
  --wait >/dev/null
log_ok "[$NAME] Gloo Operator ready"

step "Creating solo-istio-license secret in istio-system"
kubectl --context "$CTX" create namespace istio-system >/dev/null 2>&1 || true
kubectl --context "$CTX" -n istio-system create secret generic solo-istio-license \
  --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
log_ok "[$NAME] license secret applied"

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

step "Patching istiod + ztunnel env vars (Ambient peering)"
ensure_env_var() {
  local ctx="$1" kind_="$2" name_="$3" var_name="$4" var_value="$5"
  local end=$(( $(date +%s) + 180 ))
  until kubectl --context "$ctx" -n istio-system get "$kind_" "$name_" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && {
      echo "  $kind_/$name_ not created within 3m — operator not reconciling?" >&2
      return 1
    }
    sleep 3
  done
  if kubectl --context "$ctx" -n istio-system get "$kind_" "$name_" \
       -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${var_name}')].name}" \
       2>/dev/null | grep -qx "$var_name"; then
    return 0
  fi
  kubectl --context "$ctx" -n istio-system patch "$kind_" "$name_" \
    --type=json -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"${var_name}\",\"value\":\"${var_value}\"}}]" \
    >/dev/null
}

ensure_env_var "$CTX" deployment istiod-gloo PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES "false"
log_ok "[$NAME] istiod env ensured"

ensure_env_var "$CTX" daemonset ztunnel L7_ENABLED "true"
log_ok "[$NAME] ztunnel env ensured"

step "Wiring SOLO_LICENSE_KEY env on istiod-gloo"
if kubectl --context "$CTX" -n istio-system get deploy istiod-gloo \
     -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='SOLO_LICENSE_KEY')].name}" \
     2>/dev/null | grep -qx "SOLO_LICENSE_KEY"; then
  log_ok "[$NAME] SOLO_LICENSE_KEY already wired"
else
  kubectl --context "$CTX" -n istio-system patch deployment istiod-gloo \
    --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/env/-",
       "value":{"name":"SOLO_LICENSE_KEY",
                "valueFrom":{"secretKeyRef":{"name":"solo-istio-license","key":"license"}}}}
    ]' >/dev/null
  log_ok "[$NAME] SOLO_LICENSE_KEY wired"
fi

step "Creating istiod alias Service"
kubectl --context "$CTX" apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: istiod
  namespace: istio-system
spec:
  selector:
    app: istiod
  ports:
  - { name: grpc-xds,       port: 15010 }
  - { name: https-dns,      port: 15012 }
  - { name: https-webhook,  port: 443, targetPort: 15017 }
  - { name: http-monitoring, port: 15014 }
YAML
log_ok "[$NAME] istiod alias Service applied"

kubectl --context "$CTX" -n istio-system rollout status deployment/istiod-gloo --timeout=120s >/dev/null
kubectl --context "$CTX" -n istio-system rollout status daemonset/ztunnel --timeout=120s >/dev/null
log_ok "istiod-gloo + ztunnel rollout complete"

# ── Step 8: East-west HBONE gateway ──────────────────────────────────────────
# Only the local half: east-west GW + LB IP. The cross-cluster peer Gateway CR
# and remote-secret cross-apply happen on the OTHER machine using the bundle
# this script emits at the end.

step "Labelling istio-system with network topology"
kubectl --context "$CTX" label ns istio-system topology.istio.io/network="$NAME" --overwrite >/dev/null

step "Installing east-west HBONE gateway (peering chart, LoadBalancer)"
kubectl --context "$CTX" create namespace istio-eastwest 2>/dev/null || true
helm upgrade --install peering-eastwest \
  "oci://us-docker.pkg.dev/soloio-img/istio-helm/peering" \
  --kube-context "$CTX" \
  --namespace istio-eastwest \
  --version "$SOLO_ISTIO_VERSION" \
  -f - >/dev/null <<EOF
eastwest:
  create: true
  cluster: ${NAME}
  network: ${NAME}
remote:
  create: false
EOF
log_ok "[$NAME] east-west GW installed"

step "Waiting for east-west LoadBalancer IP"
EW_IP=""
for i in $(seq 1 40); do
  EW_IP="$(kubectl --context "$CTX" -n istio-eastwest \
    get svc istio-eastwest -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$EW_IP" ]] && break
  sleep 3
done
[[ -n "$EW_IP" ]] || die "east-west LB IP not assigned — check MetalLB pool capacity"
log_ok "[$NAME] east-west GW: $EW_IP"

# ── Step 9: Namespace labels for agentgateway-system ─────────────────────────

step "Labelling agentgateway-system for Ambient + network topology"
kubectl --context "$CTX" create namespace agentgateway-system 2>/dev/null || true
kubectl --context "$CTX" label namespace agentgateway-system \
  istio.io/dataplane-mode=ambient \
  topology.istio.io/network="$NAME" \
  --overwrite >/dev/null
log_ok "[$NAME] agentgateway-system labelled"

# ── Step 10: Enterprise agentgateway ─────────────────────────────────────────

if [[ -n "$AGW_IMAGE_REGISTRY" ]]; then
  step "Pre-pulling Enterprise agentgateway images ($AGW_VERSION) from $AGW_IMAGE_REGISTRY"
  AGW_TAG="${AGW_VERSION#v}"
  for IMG in enterprise-agentgateway-controller agentgateway-enterprise; do
    REF="${AGW_IMAGE_REGISTRY}/${IMG}:${AGW_TAG}"
    if docker image inspect "$REF" >/dev/null 2>&1; then
      log_ok "cached: $IMG"
    else
      log "pulling $IMG..."
      docker pull --quiet --platform "$KIND_PLATFORM" "$REF" >/dev/null
      log_ok "$IMG pulled"
    fi
  done
  loaded=0; skipped=0
  for ROLE in control-plane worker; do
    NODE="${NAME}-${ROLE}"
    for IMG in enterprise-agentgateway-controller agentgateway-enterprise; do
      REF="${AGW_IMAGE_REGISTRY}/${IMG}:${AGW_TAG}"
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
  log_ok "[$NAME] AG images loaded: $loaded new, $skipped already present"
fi

step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
helm upgrade --install agentgateway-crds \
  "${AGW_REGISTRY}/enterprise-agentgateway-crds" \
  --kube-context "$CTX" \
  --namespace agentgateway-system \
  --version "$AGW_VERSION" \
  --wait >/dev/null
log_ok "[$NAME] CRDs installed"

step "Installing Enterprise agentgateway control plane $AGW_VERSION"
helm upgrade --install enterprise-agentgateway \
  "${AGW_REGISTRY}/enterprise-agentgateway" \
  --kube-context "$CTX" \
  --namespace agentgateway-system \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait >/dev/null
log_ok "[$NAME] Enterprise agentgateway installed"

# ── Step 11: Single-cluster smoke test ────────────────────────────────────────

step "Smoke test — platform health"
INFRA_OK=yes

for GC in enterprise-agentgateway enterprise-agentgateway-waypoint; do
  if kubectl --context "$CTX" get gatewayclass "$GC" >/dev/null 2>&1; then
    log_ok "[$NAME] GatewayClass $GC registered"
  else
    log "[$NAME] GatewayClass $GC MISSING"
    INFRA_OK=no
  fi
done

if kubectl --context "$CTX" -n istio-system get deploy istiod-gloo \
     -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null \
     | grep -qx True; then
  log_ok "[$NAME] istiod-gloo Available"
else
  log "[$NAME] istiod-gloo NOT Available"; INFRA_OK=no
fi

if kubectl --context "$CTX" -n istio-system get ds ztunnel \
     -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null \
     | grep -qE '^([0-9]+)/\1$'; then
  log_ok "[$NAME] ztunnel fully scheduled"
else
  log "[$NAME] ztunnel not fully scheduled"; INFRA_OK=no
fi

if kubectl --context "$CTX" -n agentgateway-system get deploy enterprise-agentgateway \
     -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null \
     | grep -qx True; then
  log_ok "[$NAME] enterprise-agentgateway controller Available"
else
  log "[$NAME] enterprise-agentgateway controller NOT Available"; INFRA_OK=no
fi

[[ -n "$EW_IP" ]] && log_ok "[$NAME] east-west GW LB IP: $EW_IP" \
  || { log "[$NAME] east-west GW has no LB IP"; INFRA_OK=no; }

if [[ "$INFRA_OK" == "yes" ]]; then
  log_ok "infrastructure smoke test — PASS"
else
  log "infrastructure smoke test — one or more checks failed; review logs above"
fi

# ── Step 17: Peering bundle for the OTHER machine ────────────────────────────
# The other machine needs three things from us:
#   1. our root-ca.crt + root-ca.key (so its intermediate CA chains back to the
#      SAME root — required for cross-cluster mTLS).
#   2. our istio-remote-secret-<NAME> kubeconfig Secret (so its istiod-gloo can
#      read OUR k8s API and discover Services + Endpoints).
#   3. our east-west GW external LB IP + cluster/network name (so its peering
#      chart can install a Remote / RemoteGateway entry pointing at us).

step "Building peering bundle for the other machine"
BUNDLE_DIR="$CERTS_DIR/peer-bundle-${NAME}"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

istioctl create-remote-secret --context "$CTX" --name "$NAME" -n istio-system 2>/dev/null \
  > "$BUNDLE_DIR/istio-remote-secret-${NAME}.yaml"
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
echo "  Solo Enterprise agentgateway — single-cluster standup"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Cluster:        $CTX"
echo "  Network:        $NAME"
echo "  Solo Istio:     $SOLO_ISTIO_VERSION"
echo "  AG:             $AGW_VERSION"
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
echo "     consuming the bundle from THIS machine (substitute its context"
echo "     name and east-west IP from its own summary block):"
echo ""
echo "       OTHER_CTX=kind-west-mini   # whatever you named the other cluster"
echo "       PEER_NAME=$NAME"
echo "       PEER_EW_IP=$EW_IP"
echo ""
echo "       # a) apply OUR remote-secret so its istiod-gloo can read our API"
echo "       kubectl --context \$OTHER_CTX apply -f /tmp/peer-bundle-\${PEER_NAME}/istio-remote-secret-\${PEER_NAME}.yaml"
echo ""
echo "       # b) install a Remote entry on its peering chart pointing at us"
echo "       helm upgrade --install remote-peers \\"
echo "         oci://us-docker.pkg.dev/soloio-img/istio-helm/peering \\"
echo "         --kube-context \$OTHER_CTX --namespace istio-eastwest \\"
echo "         --version $SOLO_ISTIO_VERSION \\"
echo "         -f - <<YAML"
echo "       eastwest: { create: false }"
echo "       remote:"
echo "         create: true"
echo "         items:"
echo "         - { cluster: \${PEER_NAME}, network: \${PEER_NAME}, trustDomain: cluster.local, address: \${PEER_EW_IP}, hbonePort: 15008, xdsPort: 15012 }"
echo "       YAML"
echo ""
echo "  5. Do the SYMMETRIC step from the other direction: ship the OTHER"
echo "     machine's peer-bundle-<name>.tar.gz back to THIS machine and run"
echo "     the same 4(a)+4(b) commands here, substituting THIS context"
echo "     ($CTX) and the OTHER cluster's east-west IP."
echo ""
echo "  6. Verify on either side (should report both clusters connected):"
echo ""
echo "       istioctl --context $CTX multicluster check"
echo ""
echo "${YEL}  Networking caveat:${RST} the OTHER machine must be able to reach"
echo "  THIS machine's east-west IP ($EW_IP) on TCP 15008 + 15012. With kind"
echo "  on macOS, $EW_IP is a Docker-bridge address that's NOT routable from"
echo "  another host. For a real cross-host demo you need to either:"
echo "    * run on Linux with a routable bridge / host-network, or"
echo "    * front the east-west Service with a port-forward / tunnel that"
echo "      publishes 15008 + 15012 on the host's LAN IP."
echo ""
echo "${YEL}────────────────────────────────────────────────────────────────────${RST}"
echo "${YEL}  Helper scripts for the cross-host networking step${RST}"
echo "${YEL}────────────────────────────────────────────────────────────────────${RST}"
echo ""
echo "  Two helpers automate steps 4(b) + the LAN tunnel:"
echo ""
echo "    ./scripts/expose-ew-on-host.sh $NAME"
echo "        Launches alpine/socat Docker containers (on the kind bridge)"
echo "        that republish 15008 + 15012 on this machine's LAN IP, so the"
echo "        peer can reach the east-west GW across the wire."
echo ""
echo "    ./scripts/peer-with.sh <local-name> <bundle.tar.gz> <peer-host:15008>"
echo "        Run on the OTHER machine after THIS one's peer bundle has been"
echo "        copied across. Verifies the shared root CA, rewrites the bundle's"
echo "        kubeconfig to a LAN-reachable kube-API endpoint, applies the"
echo "        remote-secret, and installs the peering helm remote entry."
echo ""
echo "  Tear the LAN tunnels down with:"
echo "    ./scripts/expose-ew-on-host.sh down $NAME"
echo ""

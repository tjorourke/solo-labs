#!/usr/bin/env bash
# quick.sh — end-to-end setup for Solo Enterprise agentgateway + Ambient multicluster
#
# Clusters: kind-east-ag (east-ag) + kind-west-ag (west-ag)
# MetalLB:  east .100-.110, west .120-.130  (non-overlapping with istio-gw demo)
#
# Usage:
#   ./quick.sh            — full setup (~15 min first run, ~5 min if images cached)
#   ./quick.sh teardown   — delete both clusters + certs/

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional: point SECRETS_FILE at a shell script that exports SOLO_ISTIO_LICENSE_KEY
# and AGENTGATEWAY_LICENSE_KEY. If unset, the script expects those two env vars to
# already be exported in the calling shell.
SECRETS_FILE="${SECRETS_FILE:-}"

CLUSTER1=kind-east-ag
CLUSTER2=kind-west-ag

GLOO_OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.3-solo}"
ISTIO_VERSION_OPERATOR="${SOLO_ISTIO_VERSION%-solo}"
# AG chart uses v-prefixed tags (2.2+). Solo switched from semver (v2.3.x) to
# calver (vYYYY.M.X) at v2026.5.0. v2026.5.1 (2026-05-22) is the latest GA on
# the public Solo registry — succeeds v2.3.3 and includes the cross-cluster
# WorkloadEntry fix (no more "unknown address type" NACK on failover).
AGW_VERSION="${AGW_VERSION:-v2026.5.1}"
AGW_REGISTRY="${AGW_REGISTRY:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
# When pulling from a private/dev registry that the kind nodes can't reach
# (e.g. the dev/nightly registry below), set AGW_IMAGE_REGISTRY to the image
# base path. The script will pre-pull the controller + dataplane images on the
# host and load them into both kind clusters before the helm install. Leave
# empty for the public Solo registry (kind nodes pull directly).
AGW_IMAGE_REGISTRY="${AGW_IMAGE_REGISTRY:-}"

# Escape hatch — flip to a dev/nightly build for pre-release testing. The
# default (v2026.5.1 GA) is what you want for normal use.
if [[ "${AGW_NIGHTLY:-false}" == "true" ]]; then
  AGW_REGISTRY="oci://us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev/charts"
  AGW_VERSION="${AGW_VERSION_NIGHTLY:-v2026.5.0-beta.4-nightly-2026-05-15}"
  AGW_IMAGE_REGISTRY="us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev"
fi
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
GLOO_MESH_VERSION="${GLOO_MESH_VERSION:-2.12.0}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
ISTIO_TAG="${SOLO_ISTIO_VERSION%-solo}"
CERTS_DIR="$REPO_ROOT/certs"

# ── Utilities ─────────────────────────────────────────────────────────────────

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "══> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

# ensure_gar_auth — idempotent gcloud auth + docker config helper for the case
# where AGW_IMAGE_REGISTRY (or any other image source) points at a private
# Google Artifact Registry. Called from the pre-pull retry path when an
# initial `docker pull` fails on a *.pkg.dev host. Triggers an interactive
# `gcloud auth login` if no auth token is available and we have a real TTY.
ensure_gar_auth() {
  local host="$1"
  if ! command -v gcloud >/dev/null 2>&1; then
    cat >&2 <<EOF

ERROR: AGW_IMAGE_REGISTRY points at a private Google Artifact Registry ($host),
but gcloud isn't installed.

  Install on macOS:  brew install --cask google-cloud-sdk
  Then:              gcloud auth login
                     gcloud auth configure-docker $host

  Or re-run quick.sh without AGW_NIGHTLY=true to use the public registry.
EOF
    exit 1
  fi
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    if [[ ! -t 0 ]]; then
      die "gcloud not authenticated and no TTY for prompt. Run: gcloud auth login (then re-run this script)"
    fi
    echo ""
    echo "  Image registry $host requires gcloud auth — running 'gcloud auth login' now."
    echo "  Browser tab will open (or follow the URL/code prompt for headless)."
    echo ""
    gcloud auth login || die "gcloud auth login failed"
  fi
  if ! grep -q "\"${host}\":" "$HOME/.docker/config.json" 2>/dev/null; then
    log "Configuring docker credential helper for $host..."
    gcloud auth configure-docker --quiet "$host" >/dev/null
  fi
  # helm OCI auth is separate from docker's credential helper — even with
  # `gcloud auth configure-docker` set up, `helm pull oci://...pkg.dev/...`
  # returns 401 unless we've also run `helm registry login`. Use the gcloud
  # access token; GAR accepts oauth2accesstoken as the username.
  #
  # Notes for the failure mode:
  #   - helm 4 on macOS stores OCI creds in the Keychain (credsStore:
  #     osxkeychain). The FIRST login pops a "Allow Keychain access?" dialog;
  #     if you dismiss it the login fails. The fix is to click "Always Allow"
  #     and re-run.
  #   - We let stderr through so that dialog / any helm error is visible;
  #     only stdout's "Login Succeeded" line is muted.
  #   - On failure we die (not warn) — otherwise the next `helm pull` 401s
  #     with a confusing "FetchReference unauthorized" error.
  log "helm registry login → $host"
  if ! gcloud auth print-access-token \
       | helm registry login -u oauth2accesstoken --password-stdin "$host" >/dev/null; then
    cat >&2 <<EOF

ERROR: helm registry login failed for $host.

  If a macOS Keychain dialog popped up, click "Always Allow" (or "Allow")
  and re-run. To verify auth manually:

    gcloud auth print-access-token \\
      | helm registry login -u oauth2accesstoken --password-stdin $host

  Expected output: "Login Succeeded".

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
  step "Tearing down agentgw clusters"
  kind delete cluster --name "${CLUSTER1#kind-}" 2>/dev/null && log_ok "${CLUSTER1#kind-} deleted" || true
  kind delete cluster --name "${CLUSTER2#kind-}" 2>/dev/null && log_ok "${CLUSTER2#kind-} deleted" || true
  rm -rf "$CERTS_DIR" && log_ok "certs/ removed" || true
  echo ""; echo "Done."; exit 0
fi

# ── Secrets ───────────────────────────────────────────────────────────────────
# Two ways to provide your Solo enterprise license keys:
#   1. Export them directly in your shell:
#        export SOLO_ISTIO_LICENSE_KEY=eyJ...
#        export AGENTGATEWAY_LICENSE_KEY=eyJ...
#   2. Point SECRETS_FILE at a sourceable shell script that exports both:
#        SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh

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
  ./scripts/quick.sh

  # option 2 — point at a sourceable file that exports both
  SECRETS_FILE=/path/to/secrets.sh ./scripts/quick.sh
EOF
  exit 1
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

# Verify docker can actually pull from a public registry. On macOS this is a
# real check, not pedantry: docker stores registry creds in the login keychain,
# and SSH sessions can't interactively unlock it. Without this guard the script
# crashes inside 'kind create' with a keychain error and a partial cluster.
#
# If the first pull fails on macOS and we have a real TTY, offer to unlock
# the login keychain inline (security will prompt for the password) then
# retry, so the user doesn't have to copy/paste a command and re-run quick.sh.
keychain_unlock_and_retry() {
  [[ "$(uname)" == "Darwin" ]] || return 1
  [[ -t 0 ]] || return 1   # need a real TTY for the password prompt
  echo ""
  echo "  Login keychain is likely locked — docker can't read its registry creds."
  echo "  Unlocking it now (Mac login password prompt will follow)."
  echo "  Ctrl-C to skip and fix manually."
  echo ""
  security -v unlock-keychain "$HOME/Library/Keychains/login.keychain-db" </dev/tty || return 1
  # Retry the pull after the unlock.
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

# ── Step 1: kind clusters ─────────────────────────────────────────────────────

step "Creating kind clusters"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
    log "[$NAME] already exists — skipping"
  else
    CFG="$REPO_ROOT/kind/${NAME}.yaml"
    [[ -f "$CFG" ]] || die "kind config not found: $CFG"
    log "[$NAME] creating..."
    kind create cluster --config "$CFG"
    log_ok "[$NAME] ready"
  fi
done

# ── Step 2: MetalLB ───────────────────────────────────────────────────────────

step "Installing MetalLB $METALLB_VERSION"
# Use {{println}} so each subnet is on its own line, then grep -v ':' to drop IPv6.
KIND_CIDR="$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1)"
[[ -n "$KIND_CIDR" ]] || die "kind Docker network not found — clusters must be up first"
# Pool must sit INSIDE the kind Docker /24 or /16, or MetalLB hands out IPs the
# other cluster's nodes can't route to (cross-cluster HBONE fails). Docker may
# assign the kind net a /24 (e.g. 192.168.97.0/24) — so take the first THREE
# octets of the actual subnet, not two + a hardcoded third. Both cluster pools
# share this /24 so the east-west LB IPs land on one L2 segment.
BASE="$(echo "$KIND_CIDR" | cut -d. -f1,2,3)"
log "kind network: $KIND_CIDR  (pool base: $BASE)"

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
    >/dev/null
done
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n metallb-system wait \
    --for=condition=Ready pod -l app=metallb,component=controller --timeout=90s >/dev/null
  log_ok "[${CTX#kind-}] MetalLB controller ready"
done

# agentgw demo uses .100-.110 / .120-.130 to avoid conflicts with the istio-gw demo
kubectl --context "$CLUSTER1" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.100-${BASE}.110"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF

kubectl --context "$CLUSTER2" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.120-${BASE}.130"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
log_ok "MetalLB pools configured  (${CLUSTER1#kind-} .100-.110  /  ${CLUSTER2#kind-} .120-.130)"

# ── Step 3: Shared root CA ────────────────────────────────────────────────────

step "Generating shared root CA + per-cluster intermediates"
mkdir -p "$CERTS_DIR"

if [[ ! -f "$CERTS_DIR/root-ca.crt" ]]; then
  openssl genrsa -out "$CERTS_DIR/root-ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 \
    -key "$CERTS_DIR/root-ca.key" \
    -subj "/O=Solo Demo/CN=Shared Root CA" \
    -out "$CERTS_DIR/root-ca.crt" 2>/dev/null
  log_ok "root CA generated"
fi

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
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
done

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  cat "$CERTS_DIR/${NAME}-ca.crt" "$CERTS_DIR/root-ca.crt" > "$CERTS_DIR/${NAME}-ca-chain.crt"
  kubectl --context "$CTX" create namespace istio-system 2>/dev/null || true
  kubectl --context "$CTX" -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$CERTS_DIR/${NAME}-ca.crt" \
    --from-file=ca-key.pem="$CERTS_DIR/${NAME}-ca.key" \
    --from-file=root-cert.pem="$CERTS_DIR/root-ca.crt" \
    --from-file=cert-chain.pem="$CERTS_DIR/${NAME}-ca-chain.crt" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
  log_ok "[$NAME] cacerts secret applied"
done

# ── Step 5: Gateway API CRDs ──────────────────────────────────────────────────

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    >/dev/null
  log_ok "[${CTX#kind-}] Gateway API CRDs applied"
done

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
#   It internally calls `ctr import --all-platforms`, which on Apple Silicon
#   fails with "content digest <sha>: not found" because Docker pulled only
#   the arm64 layers from a multi-arch manifest. Without --all-platforms,
#   ctr imports just the host-native arch and succeeds. Pipe `docker save`
#   directly into `ctr import -` on each kind node.
# Skip per-image-per-node if already loaded (resumable on rerun).
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
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
done

# ── Step 7: Gloo Operator + Solo Istio ───────────────────────────────────────

step "Installing Gloo Operator $GLOO_OPERATOR_VERSION"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  helm upgrade --install gloo-operator \
    oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator \
    --kube-context "$CTX" \
    --namespace gloo-system --create-namespace \
    --version "$GLOO_OPERATOR_VERSION" \
    --wait >/dev/null
  log_ok "[${CTX#kind-}] Gloo Operator ready"
done

step "Creating solo-istio-license secret in istio-system"
# istiod-gloo runs in istio-system and reads SOLO_LICENSE_KEY via secretKeyRef
# from this Secret — the Secret MUST be in the same namespace as the pod.
# (The env wire-up itself is patched on after istiod is created — see below.)
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" create namespace istio-system >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n istio-system create secret generic solo-istio-license \
    --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
  log_ok "[${CTX#kind-}] license secret applied"
done

step "Applying ServiceMeshController CRs"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
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
done

step "Waiting for istiod-gloo"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  wait_deploy "$CTX" istio-system istiod-gloo 300s
  log_ok "[${CTX#kind-}] istiod-gloo ready"
done

step "Patching istiod + ztunnel env vars (Ambient peering)"
# Helper: append an env var to a container only if it isn't already set.
# JSON Patch "add" on /env/- always appends — re-running would create duplicates.
# Also polls for resource existence (the operator may not have created it yet).
ensure_env_var() {
  local ctx="$1" kind_="$2" name="$3" var_name="$4" var_value="$5"
  local end=$(( $(date +%s) + 180 ))
  until kubectl --context "$ctx" -n istio-system get "$kind_" "$name" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $end ]] && {
      echo "  $kind_/$name not created within 3m — operator not reconciling?" >&2
      return 1
    }
    sleep 3
  done
  if kubectl --context "$ctx" -n istio-system get "$kind_" "$name" \
       -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${var_name}')].name}" \
       2>/dev/null | grep -qx "$var_name"; then
    return 0  # already present
  fi
  kubectl --context "$ctx" -n istio-system patch "$kind_" "$name" \
    --type=json -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"${var_name}\",\"value\":\"${var_value}\"}}]" \
    >/dev/null
}

# istiod — disable K8s WorkloadEntry selection so cross-cluster endpoints
# resolve via the east-west GW, not WorkloadEntries.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  ensure_env_var "$CTX" deployment istiod-gloo PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES "false"
  log_ok "[${CTX#kind-}] istiod env ensured"
done

# ztunnel — enable L7-aware HBONE so traffic can flow through waypoints across clusters.
# The operator creates the ztunnel DaemonSet a few seconds after istiod-gloo is
# Available; ensure_env_var polls for its existence.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  ensure_env_var "$CTX" daemonset ztunnel L7_ENABLED "true"
  log_ok "[${CTX#kind-}] ztunnel env ensured"
done

# istiod — wire SOLO_LICENSE_KEY from the solo-istio-license Secret. The pilot-discovery
# binary only reads this env var (not a mount, not LICENSE_KEY / GLOO_LICENSE_KEY).
# Without this, multicluster features stay locked even with a valid JWT in the Secret.
step "Wiring SOLO_LICENSE_KEY env on istiod-gloo"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  if kubectl --context "$CTX" -n istio-system get deploy istiod-gloo \
       -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='SOLO_LICENSE_KEY')].name}" \
       2>/dev/null | grep -qx "SOLO_LICENSE_KEY"; then
    log_ok "[${CTX#kind-}] SOLO_LICENSE_KEY already wired"
    continue
  fi
  kubectl --context "$CTX" -n istio-system patch deployment istiod-gloo \
    --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/env/-",
       "value":{"name":"SOLO_LICENSE_KEY",
                "valueFrom":{"secretKeyRef":{"name":"solo-istio-license","key":"license"}}}}
    ]' >/dev/null
  log_ok "[${CTX#kind-}] SOLO_LICENSE_KEY wired"
done

step "Creating istiod alias Service"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
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
  log_ok "[${CTX#kind-}] istiod alias Service applied"
done

# Wait for rollouts after env patches. The env patch restarts istiod + ztunnel;
# on a first run (cold image cache, multiple kind clusters sharing the host)
# that can take a few minutes, so give it 5m rather than a tight 2m.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system rollout status deployment/istiod-gloo --timeout=300s >/dev/null
  kubectl --context "$CTX" -n istio-system rollout status daemonset/ztunnel --timeout=300s >/dev/null
done
log_ok "istiod-gloo + ztunnel rollout complete on both clusters"

# ── Step 8: East-west HBONE gateways ─────────────────────────────────────────

step "Labelling istio-system with network topology"
kubectl --context "$CLUSTER1" label ns istio-system topology.istio.io/network="${CLUSTER1#kind-}" --overwrite >/dev/null
kubectl --context "$CLUSTER2" label ns istio-system topology.istio.io/network="${CLUSTER2#kind-}" --overwrite >/dev/null

step "Installing east-west HBONE gateways (peering chart, LoadBalancer)"
# LoadBalancer type — MetalLB assigns an external IP from the configured pool.
# This mirrors a real-world deployment where the east-west GW is reachable on
# a cloud LB, not a fragile kind node + NodePort tuple.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
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
done

# Wait for MetalLB to assign LB IPs to both east-west services.
step "Waiting for east-west LoadBalancer IPs"
wait_lb_ip() {
  local ctx="$1"
  local ip=""
  for i in $(seq 1 40); do
    ip="$(kubectl --context "$ctx" -n istio-eastwest \
      get svc istio-eastwest -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    sleep 3
  done
  echo ""
}
EAST_EW_IP="$(wait_lb_ip "$CLUSTER1")"
WEST_EW_IP="$(wait_lb_ip "$CLUSTER2")"
[[ -n "$EAST_EW_IP" ]] || die "east east-west LB IP not assigned — check MetalLB pool capacity"
[[ -n "$WEST_EW_IP" ]] || die "west east-west LB IP not assigned — check MetalLB pool capacity"
log_ok "east-ag east-west GW: $EAST_EW_IP    west-ag east-west GW: $WEST_EW_IP"

step "Adding remote peer references (HBONE 15008, XDS 15012 on the LB IPs)"
helm upgrade --install remote-peers \
  "oci://us-docker.pkg.dev/soloio-img/istio-helm/peering" \
  --kube-context "$CLUSTER1" --namespace istio-eastwest \
  --version "$SOLO_ISTIO_VERSION" \
  -f - >/dev/null <<EOF
eastwest: { create: false }
remote:
  create: true
  items:
  - { cluster: ${CLUSTER2#kind-}, network: ${CLUSTER2#kind-}, trustDomain: cluster.local, address: ${WEST_EW_IP}, hbonePort: 15008, xdsPort: 15012 }
EOF
log_ok "[${CLUSTER1#kind-}] peer → ${CLUSTER2#kind-} @ ${WEST_EW_IP}"

helm upgrade --install remote-peers \
  "oci://us-docker.pkg.dev/soloio-img/istio-helm/peering" \
  --kube-context "$CLUSTER2" --namespace istio-eastwest \
  --version "$SOLO_ISTIO_VERSION" \
  -f - >/dev/null <<EOF
eastwest: { create: false }
remote:
  create: true
  items:
  - { cluster: ${CLUSTER1#kind-}, network: ${CLUSTER1#kind-}, trustDomain: cluster.local, address: ${EAST_EW_IP}, hbonePort: 15008, xdsPort: 15012 }
EOF
log_ok "[${CLUSTER2#kind-}] peer → ${CLUSTER1#kind-} @ ${EAST_EW_IP}"

step "Cross-applying remote secrets (istiod control-plane discovery)"
istioctl create-remote-secret --context "$CLUSTER1" --name "${CLUSTER1#kind-}" 2>/dev/null \
  | kubectl --context "$CLUSTER2" apply -f - >/dev/null
log_ok "[${CLUSTER2#kind-}] remote secret for ${CLUSTER1#kind-} applied"

istioctl create-remote-secret --context "$CLUSTER2" --name "${CLUSTER2#kind-}" 2>/dev/null \
  | kubectl --context "$CLUSTER1" apply -f - >/dev/null
log_ok "[${CLUSTER1#kind-}] remote secret for ${CLUSTER2#kind-} applied"

step "Verifying peering ($CLUSTER1 → $CLUSTER2)"
# Tolerate the "found invalid license for multicluster" warning — basic HBONE
# peering still works without the GlobalService entitlement. Peers Check is
# the assertion that matters.
if istioctl --context "$CLUSTER1" multicluster check 2>&1 | grep -qE 'Peers Check.*all clusters connected'; then
  log_ok "peering verified — both clusters connected"
else
  log "multicluster check did not confirm peering — continuing anyway (cross-cluster traffic may need a few seconds to converge)"
fi

# ── Step 9: Namespace labels for agentgateway-system ─────────────────────────
# Only label the platform's own namespace. Lab workloads (bookinfo, ai-tools,
# ai-agents) are deployed by the dedicated lab pages — they'll create their
# own namespaces and apply ambient + topology labels themselves.

step "Labelling agentgateway-system for Ambient + network topology"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  kubectl --context "$CTX" create namespace agentgateway-system 2>/dev/null || true
  kubectl --context "$CTX" label namespace agentgateway-system \
    istio.io/dataplane-mode=ambient \
    topology.istio.io/network="$NAME" \
    --overwrite >/dev/null
  log_ok "[$NAME] agentgateway-system labelled"
done

# ── Step 10: Enterprise agentgateway ─────────────────────────────────────────

# If the chart registry is a private Google Artifact Registry (e.g. the nightly
# dev repo), authenticate gcloud + docker + helm up front. Without this, the
# `helm upgrade --install agentgateway-crds` call below 401s — helm OCI auth
# is independent of docker's credential helper, so configuring docker alone
# isn't enough.
AGW_REGISTRY_HOST="$(echo "$AGW_REGISTRY" | sed 's|^oci://||' | cut -d/ -f1)"
if [[ "$AGW_REGISTRY_HOST" == *pkg.dev ]]; then
  step "Authenticating to private chart registry $AGW_REGISTRY_HOST"
  ensure_gar_auth "$AGW_REGISTRY_HOST"
  log_ok "gcloud + docker + helm authenticated for $AGW_REGISTRY_HOST"
fi

# When using a private/dev registry the kind nodes can't authenticate to, pre-pull
# the controller + dataplane images on the host and load them into both clusters.
# AGW_IMAGE_REGISTRY is set automatically by AGW_NIGHTLY=true; users can also set
# it explicitly to test other dev builds.
if [[ -n "$AGW_IMAGE_REGISTRY" ]]; then
  step "Pre-pulling Enterprise agentgateway images ($AGW_VERSION) from $AGW_IMAGE_REGISTRY"
  AGW_TAG="${AGW_VERSION#v}"
  for IMG in enterprise-agentgateway-controller agentgateway-enterprise; do
    REF="${AGW_IMAGE_REGISTRY}/${IMG}:${AGW_TAG}"
    if docker image inspect "$REF" >/dev/null 2>&1; then
      log_ok "cached: $IMG"
    else
      log "pulling $IMG..."
      if ! docker pull --quiet --platform "$KIND_PLATFORM" "$REF" >/dev/null 2>&1; then
        # On *.pkg.dev (Google Artifact Registry) the most common cause is
        # unauthenticated access — kick off gcloud auth + docker configure
        # then retry once.
        AGW_GAR_HOST="${AGW_IMAGE_REGISTRY%%/*}"
        if [[ "$AGW_GAR_HOST" == *pkg.dev ]]; then
          ensure_gar_auth "$AGW_GAR_HOST"
          docker pull --quiet --platform "$KIND_PLATFORM" "$REF" >/dev/null
        else
          die "failed to pull $REF (non-GAR host — check the registry path)"
        fi
      fi
      log_ok "$IMG pulled"
    fi
  done
  for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
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
    log_ok "[$NAME] images loaded: $loaded new, $skipped already present"
  done
fi

step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  helm upgrade --install agentgateway-crds \
    "${AGW_REGISTRY}/enterprise-agentgateway-crds" \
    --kube-context "$CTX" \
    --namespace agentgateway-system \
    --version "$AGW_VERSION" \
    --wait >/dev/null
  log_ok "[${CTX#kind-}] CRDs installed"
done

step "Installing Enterprise agentgateway control plane $AGW_VERSION"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  # tokenExchange is enabled later by init-demo.sh once Keycloak is up
  # (the STS validators in tokenExchange config reference Keycloak's JWKS,
  # so AGW would crash-loop if we enabled it before Keycloak exists).
  helm upgrade --install enterprise-agentgateway \
    "${AGW_REGISTRY}/enterprise-agentgateway" \
    --kube-context "$CTX" \
    --namespace agentgateway-system \
    --version "$AGW_VERSION" \
    --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
    --wait >/dev/null
  log_ok "[$NAME] Enterprise agentgateway installed"
done

# ── Step 11: Solo Enterprise management chart (ClickHouse + UI + telemetry) ───
# Adds solo-enterprise-ui, ClickHouse, and the OTel telemetry collectors
# referenced by the agentgateway-enterprise-demo notebook §9. Installed only
# on CLUSTER1 (single-pane-of-glass; no need on the peer cluster).

SOLO_MGMT_CHART="oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management"
SOLO_MGMT_VERSION="${SOLO_MGMT_VERSION:-0.4.3}"

if [[ "${SKIP_SOLO_MGMT:-false}" == "true" ]]; then
  step "Skipping Solo Enterprise management chart (SKIP_SOLO_MGMT=true)"
else
  step "Installing Solo Enterprise management chart $SOLO_MGMT_VERSION on ${CLUSTER1#kind-}"
  helm upgrade --install solo-enterprise-mgmt "$SOLO_MGMT_CHART" \
    --kube-context "$CLUSTER1" \
    --namespace agentgateway-system \
    --version "$SOLO_MGMT_VERSION" \
    --set cluster="${CLUSTER1#kind-}" \
    --set products.agentgateway.enabled=true \
    --set products.agentgateway.namespace=agentgateway-system \
    --set licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
    --set clickhouse.persistentVolume.enabled=false \
    --wait --timeout 8m >/dev/null
  log_ok "[${CLUSTER1#kind-}] solo-enterprise management chart installed"

  # Wait for the UI Service so init-demo.sh can resolve it deterministically.
  for i in $(seq 1 30); do
    if kubectl --context "$CLUSTER1" -n agentgateway-system get svc solo-enterprise-ui >/dev/null 2>&1; then
      log_ok "[${CLUSTER1#kind-}] solo-enterprise-ui Service ready"
      break
    fi
    sleep 2
  done
fi

# ── Step 12: Keycloak (Auth0 substitute for the demo notebook §7-§8) ──────────
# Mirrors solo-demos/keycloak-setup: realm 'solo', client 'kagent' (password
# grant), users alice/bob/carol with field-fte/field-trial/field-admin groups.
# The demo notebook reads Auth0 creds from ~/.auth0.env; init-demo.sh emits a
# Keycloak-populated file at that path so the notebook setup cell needs no
# code changes — only the OAuth2 token URL in §8 cell 53 changes (Keycloak's
# /realms/.../protocol/openid-connect/token instead of Auth0's /oauth/token).

KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
KEYCLOAK_REALM_JSON="$REPO_ROOT/yaml/keycloak/realm-solo.json"
KEYCLOAK_MANIFEST="$REPO_ROOT/yaml/keycloak/keycloak.yaml"

if [[ "${SKIP_KEYCLOAK:-false}" == "true" ]]; then
  step "Skipping Keycloak (SKIP_KEYCLOAK=true)"
elif [[ ! -f "$KEYCLOAK_REALM_JSON" || ! -f "$KEYCLOAK_MANIFEST" ]]; then
  log "Keycloak assets missing under yaml/keycloak/ — skipping Keycloak install"
else
  step "Installing Keycloak (realm solo) on ${CLUSTER1#kind-}"
  # Upstream quay.io/keycloak/keycloak via raw manifest. We dropped the
  # bitnami chart because docker.io/bitnami/keycloak:*-debian-12-r* was
  # pulled from Docker Hub when Bitnami ended free distribution in 2025.
  kubectl --context "$CLUSTER1" create namespace "$KEYCLOAK_NS" \
    --dry-run=client -o yaml | kubectl --context "$CLUSTER1" apply -f - >/dev/null
  kubectl --context "$CLUSTER1" -n "$KEYCLOAK_NS" create configmap keycloak-realm-import \
    --from-file=realm-solo.json="$KEYCLOAK_REALM_JSON" \
    --dry-run=client -o yaml | kubectl --context "$CLUSTER1" apply -f - >/dev/null
  kubectl --context "$CLUSTER1" apply -f "$KEYCLOAK_MANIFEST" >/dev/null
  # quay.io/keycloak/keycloak is a large image; a cold first pull can take
  # several minutes, so allow 10m before treating the rollout as stuck.
  kubectl --context "$CLUSTER1" -n "$KEYCLOAK_NS" \
    rollout status statefulset/keycloak --timeout 10m >/dev/null
  log_ok "[${CLUSTER1#kind-}] Keycloak installed (realm: solo, ns: $KEYCLOAK_NS)"
fi

# ── Step 13: Infra smoke test ─────────────────────────────────────────────────
# No workload deployment — quick.sh is platform-only. The lab pages
# (agentgw-cloud-connectivity, agentgw-agentic-mcp) install their own test
# workloads. Verify the infra is healthy.

step "Smoke test — platform health"
INFRA_OK=yes

# 1) AG GatewayClasses registered on both clusters
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  for GC in enterprise-agentgateway enterprise-agentgateway-waypoint; do
    if kubectl --context "$CTX" get gatewayclass "$GC" >/dev/null 2>&1; then
      log_ok "[${CTX#kind-}] GatewayClass $GC registered"
    else
      log "[${CTX#kind-}] GatewayClass $GC MISSING"
      INFRA_OK=no
    fi
  done
done

# 2) AG controller + ztunnel Available
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  if kubectl --context "$CTX" -n agentgateway-system get deploy enterprise-agentgateway \
       -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null \
       | grep -qx True; then
    log_ok "[${CTX#kind-}] enterprise-agentgateway controller Available"
  else
    log "[${CTX#kind-}] enterprise-agentgateway controller NOT Available"
    INFRA_OK=no
  fi
  # ztunnel ready = N/N where both sides equal AND > 0. Avoid grep -E '\1'
  # because ugrep (Homebrew grep replacement) rejects backreferences.
  ready="$(kubectl --context "$CTX" -n istio-system get ds ztunnel \
            -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"
  IFS=/ read -r r d <<< "$ready"
  if [[ -n "$r" && "$r" == "$d" && "${r:-0}" -gt 0 ]]; then
    log_ok "[${CTX#kind-}] ztunnel fully scheduled ($ready)"
  else
    log "[${CTX#kind-}] ztunnel not fully scheduled ($ready)"
    INFRA_OK=no
  fi
done

# 3) Multicluster peering verified. istiod needs a few seconds to push the
#    remote endpoints after the peer references land, so retry rather than
#    fail on the first (pre-convergence) check.
PEERING_OK=no
for _ in 1 2 3 4 5 6; do
  if istioctl --context "$CLUSTER1" multicluster check 2>&1 \
       | grep -qE 'Peers Check.*all clusters connected'; then
    PEERING_OK=yes
    break
  fi
  sleep 10
done
if [[ "$PEERING_OK" == "yes" ]]; then
  log_ok "[${CLUSTER1#kind-}] multicluster peering verified — both clusters connected"
else
  log "[${CLUSTER1#kind-}] multicluster check did not confirm peering after 60s"
  INFRA_OK=no
fi

if [[ "$INFRA_OK" == "yes" ]]; then
  log_ok "infrastructure smoke test — PASS"
else
  log "infrastructure smoke test — one or more checks failed; review logs above"
fi

# ── Step 17: Gloo Management Plane / UI (optional) ────────────────────────────
# Only runs if GLOO_MESH_LICENSE_KEY is set. Mirrors HTML STEP 15. Installs the
# Gloo Platform mgmt server on east-ag + registers west-ag as a workload
# cluster. ~3-5 min on first run; idempotent (helm upgrade --install + a
# meshctl-skip-if-registered check).
GLOO_UI_INSTALLED="no"
if [[ -n "${GLOO_MESH_LICENSE_KEY:-}" ]]; then
  step "Installing Gloo Management Plane v$GLOO_MESH_VERSION (optional)"
  if ! command -v meshctl >/dev/null 2>&1; then
    log "meshctl not found — to install run:"
    log "  curl -sL https://run.solo.io/meshctl/install | GLOO_MESH_VERSION=v$GLOO_MESH_VERSION sh -"
    log "  export PATH=\$HOME/.gloo-mesh/bin:\$PATH"
    log "skipping Gloo UI install"
  else
    helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts >/dev/null 2>&1 || true
    helm repo update gloo-platform >/dev/null 2>&1

    helm upgrade --install gloo-platform-crds gloo-platform/gloo-platform-crds \
      --kube-context "$CLUSTER1" \
      --namespace gloo-mesh --create-namespace \
      --version "$GLOO_MESH_VERSION" \
      --set installEnterpriseCrds=false \
      --wait --timeout 3m >/dev/null
    log_ok "gloo-platform-crds installed"

    cat > /tmp/mgmt-values.yaml <<EOF
common:
  cluster: ${CLUSTER1#kind-}
glooAgent:
  enabled: true
  runAsSidecar: true
  relay:
    serverAddress: gloo-mesh-mgmt-server.gloo-mesh:9900
glooAnalyzer: { enabled: true }
glooMgmtServer:
  enabled: true
  registerCluster: true
  policyApis: { enabled: true }
glooInsightsEngine: { enabled: true }
glooUi: { enabled: true }
prometheus: { enabled: true }
redis:
  deployment: { enabled: true }
telemetryCollector: { enabled: true }
telemetryGateway: { enabled: true }
telemetryGatewayCustomization:
  pipelines:
    traces/jaeger: { enabled: true }
telemetryCollectorCustomization:
  pipelines:
    traces/istio: { enabled: true }
installEnterpriseCrds: false
featureGates:
  ConfigDistribution: false
EOF

    # gloo-platform 2.12.0 chart deploys the mgmt-server pod with a gloo-agent
    # sidecar (glooAgent.runAsSidecar: true), and both containers declare
    # ports with identical names (stats/grpc/healthcheck) but different
    # numbers. Kubernetes prints a warning per duplicate per stderr line.
    # The pod still admits and runs — port-by-name lookups always pick
    # container[0]'s value, and gloo-platform's Services target by number,
    # not name. Filter out exactly these three warnings to keep the output
    # clean; surface anything else gloo emits on stderr.
    helm upgrade --install gloo-platform gloo-platform/gloo-platform \
      --kube-context "$CLUSTER1" \
      --namespace gloo-mesh \
      --version "$GLOO_MESH_VERSION" \
      --values /tmp/mgmt-values.yaml \
      --set licensing.glooMeshLicenseKey="$GLOO_MESH_LICENSE_KEY" \
      --wait --timeout 5m >/dev/null \
      2> >(grep -Ev 'duplicate port name "(stats|grpc|healthcheck)"' >&2)
    log_ok "gloo-platform installed on ${CLUSTER1#kind-}"

    # Wait for telemetry-gateway LB IP (MetalLB needs ~10-30s)
    TG_IP=""
    for i in $(seq 1 40); do
      TG_IP="$(kubectl --context "$CLUSTER1" -n gloo-mesh \
        get svc gloo-telemetry-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      [[ -n "$TG_IP" ]] && break
      sleep 3
    done
    if [[ -z "$TG_IP" ]]; then
      log "telemetry-gateway LB IP not assigned — Gloo UI install incomplete"
    else
      log_ok "telemetry-gateway: $TG_IP:4317"
      # Register the peer cluster so the UI service graph spans both clusters.
      # gloo-platform-crds and enterprise-agentgateway-crds both ship the
      # extauth/ratelimit CRDs, so on the peer (where AGW CRDs are already
      # installed) Helm refuses to import a CRD owned by the agentgateway-crds
      # release. Re-annotate just those two shared CRDs to the gloo-platform-crds
      # release so meshctl's CRD install can adopt them, then register.
      for CRD in authconfigs.extauth.solo.io ratelimitconfigs.ratelimit.solo.io; do
        kubectl --context "$CLUSTER2" annotate crd "$CRD" \
          meta.helm.sh/release-name=gloo-platform-crds \
          meta.helm.sh/release-namespace=gloo-mesh --overwrite >/dev/null 2>&1 || true
        kubectl --context "$CLUSTER2" label crd "$CRD" \
          app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
      done
      if meshctl cluster register "${CLUSTER2#kind-}" \
           --kubecontext "$CLUSTER1" \
           --profiles gloo-mesh-agent \
           --remote-context "$CLUSTER2" \
           --telemetry-server-address "$TG_IP:4317" >/dev/null 2>&1; then
        log_ok "[${CLUSTER2#kind-}] registered as workload cluster — UI graph spans both"
      else
        log "[${CLUSTER2#kind-}] cross-cluster UI register failed — UI on ${CLUSTER1#kind-} only"
      fi
      GLOO_UI_INSTALLED="yes"
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Solo Enterprise agentgateway — Ambient Multicluster on kind"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Clusters:   $CLUSTER1   $CLUSTER2"
echo "  Solo Istio: $SOLO_ISTIO_VERSION"
echo "  AG:         $AGW_VERSION"
echo ""
echo "  Platform is up. To run a lab, head to one of:"
echo "    https://tjorourke.github.io/solo/agentgw-cloud-connectivity/"
echo "      (cross-cluster failover, in-cluster L7 waypoint, egress)"
echo "    https://tjorourke.github.io/solo/agentgw-agentic-mcp/"
echo "      (MCP federation, JWT RBAC, OAuth2 token exchange)"
echo ""
echo "  Verify peering (both should show 'remote clusters: 1'):"
echo "    istioctl --context $CLUSTER1 multicluster check"
echo ""
echo "  Run the agentgateway-enterprise-demo notebook:"
echo "    ./scripts/init-demo.sh                # Gateway + Keycloak port-forward + ~/.auth0.env"
echo "    cd /path/to/agentgateway-enterprise-demo && ./init.sh"
echo "    jupyter notebook demo.ipynb"
echo ""
echo "  ⚠ One-time notebook patch (§8 cell 53) — Keycloak token URL differs from Auth0:"
echo "      -    \"https://\$AUTH0_DOMAIN/oauth/token\""
echo "      +    \"http://\$AUTH0_DOMAIN\${AUTH0_TOKEN_PATH:-/oauth/token}\""
echo "    (init-demo.sh sets AUTH0_TOKEN_PATH to /realms/solo/protocol/openid-connect/token.)"
echo ""
if [[ "$GLOO_UI_INSTALLED" == "yes" ]]; then
  echo "  Launch Gloo UI:"
  echo "    meshctl dashboard"
  echo ""
fi
echo "  Teardown:"
echo "    ./quick.sh teardown"
echo ""

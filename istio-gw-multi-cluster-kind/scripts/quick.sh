#!/usr/bin/env bash
# quick.sh — end-to-end setup for Solo Enterprise Istio Ambient multicluster
#
# Follows the rvennam/ambient-multicluster-workshop flow with kind fixes applied.
# Clusters: kind-east-istio (east-istio) + kind-west-istio (west-istio)
# MetalLB:  east .200-.210, west .220-.230  (non-overlapping with agentgw demo)
#
# Usage:
#   ./quick.sh            — full setup (~15 min first run, ~5 min if images cached)
#   ./quick.sh teardown   — delete both clusters + certs/

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-/Users/tomorourke/code/solo/secrets/secrets-envs.sh}"

CLUSTER1=kind-east-istio
CLUSTER2=kind-west-istio

GLOO_OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.3-solo}"
ISTIO_VERSION_OPERATOR="${SOLO_ISTIO_VERSION%-solo}"   # 1.29.2 — for SMC .spec.version
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"   # v1.5.0 ships a safe-upgrades ValidatingAdmissionPolicy that blocks SMC's bundled CRD install
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
ISTIO_TAG="${SOLO_ISTIO_VERSION}"                       # 1.29.2-solo — keep -solo, image tags include it
CERTS_DIR="$REPO_ROOT/certs"

# ── Utilities ─────────────────────────────────────────────────────────────────

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "══> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

wait_deploy() {
  # Poll for existence first — kubectl wait does NOT retry on NotFound, so
  # waiting before the controller has created the Deployment fails immediately.
  # The SMC reconciler creates istiod-gloo a few seconds after the SMC CR applies;
  # the operator-managed CNI + ztunnel DaemonSets appear shortly after.
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
  step "Tearing down istio-gw clusters"
  kind delete cluster --name "${CLUSTER1#kind-}" 2>/dev/null && log_ok "${CLUSTER1#kind-} deleted" || true
  kind delete cluster --name "${CLUSTER2#kind-}" 2>/dev/null && log_ok "${CLUSTER2#kind-} deleted" || true
  rm -rf "$CERTS_DIR" && log_ok "certs/ removed" || true
  echo ""; echo "Done."; exit 0
fi

# ── Secrets ───────────────────────────────────────────────────────────────────

[[ -f "$SECRETS_FILE" ]] && { set -a; source "$SECRETS_FILE"; set +a; }
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || die "SOLO_ISTIO_LICENSE_KEY not set (source secrets-envs.sh)"

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
BASE="$(echo "$KIND_CIDR" | cut -d. -f1,2)"
log "kind network: $KIND_CIDR  (base: $BASE)"

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

# istio-gw demo uses .200-.210 / .220-.230
kubectl --context "$CLUSTER1" apply -f - >/dev/null <<EOF
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

kubectl --context "$CLUSTER2" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.255.220-${BASE}.255.230"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
log_ok "MetalLB pools configured  (${CLUSTER1#kind-} .200-.210  /  ${CLUSTER2#kind-} .220-.230)"

# ── Step 3: Shared root CA ────────────────────────────────────────────────────
# (Bookinfo + ingress are deferred to a separate lab — this script provisions
# the platform only, matching the agentgw-multi-cluster-kind standup pattern.)

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
  kubectl --context "$CTX" create namespace istio-gateways 2>/dev/null || true
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
# Why we bypass `kind load docker-image`:
#   It internally calls `ctr import --all-platforms`, which on Apple Silicon
#   fails with "content digest <sha>: not found" because Docker pulled only
#   the arm64 layers from a multi-arch manifest. Without --all-platforms,
#   ctr imports just the host-native arch and succeeds. Pipe `docker save`
#   directly into `ctr import -` on each kind node.
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
    --set manager.env.SOLO_ISTIO_LICENSE_KEY="${SOLO_ISTIO_LICENSE_KEY}" \
    --wait >/dev/null
  log_ok "[${CTX#kind-}] Gloo Operator ready"
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

step "Creating solo-istio-license secret in istio-system"
# pilot-discovery only reads SOLO_LICENSE_KEY as an env var (not /etc/license-keys mounts,
# not LICENSE_KEY / GLOO_LICENSE_KEY). The Secret must live alongside istiod-gloo for
# secretKeyRef to resolve — gloo-system is wrong.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system create secret generic solo-istio-license \
    --from-literal=license="${SOLO_ISTIO_LICENSE_KEY}" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
  log_ok "[${CTX#kind-}] license secret applied"
done

# Helper: append an env var to a container only if it isn't already set.
# JSON Patch "add" on /env/- always appends — re-running would create duplicates
# (Kubernetes prints a "hides previous definition of X" warning per duplicate).
# Also polls for resource existence (operator may not have created it yet).
ensure_env_var() {
  # ensure_env_var ctx kind name var_name [--value VALUE | --secret-ref SECRET KEY]
  local ctx="$1" kind_="$2" name="$3" var_name="$4"; shift 4
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
  # Build the value payload — either a literal or a secretKeyRef.
  local value_json
  if [[ "$1" == "--value" ]]; then
    value_json="\"value\":\"$2\""
  elif [[ "$1" == "--secret-ref" ]]; then
    value_json="\"valueFrom\":{\"secretKeyRef\":{\"name\":\"$2\",\"key\":\"$3\"}}"
  else
    echo "ensure_env_var: bad args" >&2; return 1
  fi
  kubectl --context "$ctx" -n istio-system patch "$kind_" "$name" \
    --type=json -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"${var_name}\",${value_json}}}]" \
    >/dev/null
}

step "Patching istiod env vars + SOLO_LICENSE_KEY"
# PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false on istiod (per Solo Ambient
# multicluster docs). SOLO_LICENSE_KEY is sourced from the Secret in istio-system.
# L7_ENABLED belongs on ztunnel, not istiod — patched separately below.
# All env-var patches are idempotent — second run skips if already present.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  ensure_env_var "$CTX" deployment istiod-gloo \
    PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES --value "false"
  ensure_env_var "$CTX" deployment istiod-gloo \
    SOLO_LICENSE_KEY --secret-ref solo-istio-license license
  log_ok "[${CTX#kind-}] istiod env ensured"
done

step "Patching ztunnel L7_ENABLED"
# L7_ENABLED=true on ztunnel enables L7-aware HBONE so traffic can traverse
# waypoints across clusters. ensure_env_var polls for the DaemonSet's existence.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  ensure_env_var "$CTX" daemonset ztunnel L7_ENABLED --value "true"
  log_ok "[${CTX#kind-}] ztunnel env ensured"
done

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system rollout status deployment/istiod-gloo --timeout=120s >/dev/null
  kubectl --context "$CTX" -n istio-system rollout status daemonset/ztunnel --timeout=120s >/dev/null
done
log_ok "istiod-gloo + ztunnel rollout complete on both clusters"

# ── Step 8: Peer clusters via istioctl multicluster expose ────────────────────

step "Waiting for istiod pods to be Running before exposing"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system wait \
    --for=condition=Ready pod -l app=istiod --timeout=120s >/dev/null
done

step "Exposing east-west gateways on both clusters"
# `istioctl multicluster expose` (Solo Istio 1.29+) applies the east-west Gateway
# resource directly to the cluster you point it at — it does NOT print YAML to
# stdout for piping. The old `expose | kubectl apply -f -` pattern fed kubectl
# the diagnostic line "Gateway istio-eastwest/istio-eastwest applied", which
# kubectl then rejected as "invalid object to validate".
# Correct flow: call expose once per cluster (no piping), then `link` to wire
# bidirectional cross-cluster discovery via istio-remote Gateways.
istioctl --context "$CLUSTER1" multicluster expose -n istio-gateways >/dev/null
log_ok "[${CLUSTER1#kind-}] east-west gateway exposed"
istioctl --context "$CLUSTER2" multicluster expose -n istio-gateways >/dev/null
log_ok "[${CLUSTER2#kind-}] east-west gateway exposed"

step "Linking clusters bidirectionally for cross-cluster discovery"
# `multicluster link` creates istio-remote Gateways in each cluster that point
# at the peer's east-west GW IP — replaces the old remote-secret dance.
istioctl multicluster link \
  --namespace istio-gateways \
  --contexts "$CLUSTER1,$CLUSTER2" >/dev/null
log_ok "${CLUSTER1#kind-} ⇄ ${CLUSTER2#kind-} linked"

# Wait for east-west gateway LoadBalancer IPs
step "Waiting for east-west gateway IPs"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  EW_IP=""
  for i in $(seq 1 30); do
    EW_IP="$(kubectl --context "$CTX" -n istio-gateways \
      get svc istio-eastwest -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$EW_IP" ]] && break
    echo -n "."; sleep 3
  done
  echo ""
  log "[${CTX#kind-}] east-west IP: ${EW_IP:-pending}"
done

# ── Step 9: Label istio-system with network topology (both clusters) ─────────
# CLAUDE.md note: topology.istio.io/network must be on every workload namespace
# AND on istio-system itself, or istiod can't classify some pods' network and
# cross-cluster endpoint rewriting silently fails. Workload namespaces get
# this label when the lab that uses them runs.

step "Labelling istio-system with network topology"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  kubectl --context "$CTX" label namespace istio-system \
    topology.istio.io/network="$NAME" --overwrite >/dev/null
  log_ok "[$NAME] istio-system labelled network=$NAME"
done

# ── Platform smoke test ──────────────────────────────────────────────────────

step "Smoke test — platform health"
fail=0
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  # istiod ready
  if ! kubectl --context "$CTX" -n istio-system get deploy istiod-gloo \
       -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null \
       | grep -qx True; then
    log "  ✗ [$NAME] istiod-gloo not Available"; fail=1
  else
    log_ok "[$NAME] istiod-gloo Available"
  fi
  # ztunnel ready — pattern is "N/N" where N is the same number on both sides
  # AND N > 0. We avoid grep backreferences (\1) because ugrep — common
  # Homebrew grep replacement — rejects them with "invalid escape" in ERE mode.
  ready="$(kubectl --context "$CTX" -n istio-system get ds ztunnel \
            -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"
  IFS=/ read -r r d <<< "$ready"
  if [[ -n "$r" && "$r" == "$d" && "${r:-0}" -gt 0 ]]; then
    log_ok "[$NAME] ztunnel: $ready"
  else
    log "  · [$NAME] ztunnel: $ready"
    fail=1
  fi
  # east-west gateway reachable — `istioctl multicluster expose` creates the
  # Service named `istio-eastwest` directly (no `istio=eastwestgateway` label
  # in this Solo Istio version — that was the sidecar/operator-era label).
  EW_IP="$(kubectl --context "$CTX" -n istio-gateways get svc istio-eastwest \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$EW_IP" ]] && log_ok "[$NAME] east-west gateway IP: $EW_IP" \
    || { log "  ✗ [$NAME] east-west gateway has no LB IP"; fail=1; }
done

# istiod sees the remote cluster
sleep 5
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  NAME="${CTX#kind-}"
  if kubectl --context "$CTX" -n istio-system logs deploy/istiod-gloo --tail=300 2>/dev/null \
       | grep -qE "Number of remote clusters: [1-9]|added cluster|peer cluster"; then
    log_ok "[$NAME] istiod sees remote cluster"
  else
    log "  · [$NAME] no 'remote cluster' log line yet — peering may still be establishing"
  fi
done

if [[ $fail -eq 0 ]]; then
  log_ok "Platform smoke test: PASS"
else
  log "Platform smoke test: FAIL — see logs above"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Solo Enterprise Istio Ambient — Multicluster Platform on kind"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Clusters:   $CLUSTER1   $CLUSTER2"
echo ""
echo "  Verify peering:"
echo "    kubectl --context $CLUSTER1 -n istio-system logs deploy/istiod-gloo | grep 'remote cluster'"
echo "    istioctl --context $CLUSTER1 multicluster check"
echo ""
echo "  Deploy a workload + run failover/L7 labs:"
echo "    See https://tjorourke.github.io/solo/ for application labs"
echo "    that build on this platform standup."
echo ""
echo "  Teardown:"
echo "    ./quick.sh teardown"
echo ""

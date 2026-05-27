#!/usr/bin/env bash
# expose-ew-on-host.sh — Republish a kind cluster's east-west GW on the host's
# LAN IP so a peer machine on the same LAN can reach it.
#
# Lab-agnostic — works for both:
#   - agentgw-multi-cluster-kind   (east-west GW in namespace istio-eastwest, ports 15008/15012)
#   - istio-gw-multi-cluster-kind  (east-west GW in namespace istio-gateways, ports 15008/15012/15021)
# Auto-detects the namespace by probing the cluster; auto-detects the ports
# by reading the Service's spec.ports. Override either with the env vars
# below if you have a non-standard layout.
#
# Why this exists: on kind + macOS the east-west GW's MetalLB-assigned LB IP
# lives on the Docker bridge (e.g. 172.18.255.100) and is NOT routable from
# another physical host. We solve that by launching alpine/socat containers
# attached to the `kind` Docker bridge (so they can dial the MetalLB IP) and
# publishing each listener port on the host's LAN IP via Docker's `-p`.
#
# Usage:
#   ./scripts/expose-ew-on-host.sh <cluster-name>           # start tunnels
#   ./scripts/expose-ew-on-host.sh down <cluster-name>      # stop tunnels
#
# Env overrides:
#   HOST_LAN_IP   — override auto-detected host LAN IP (e.g. for VPN/WG NIC).
#   SOCAT_IMAGE   — alpine/socat image ref (default alpine/socat:latest).
#   EW_NAMESPACE  — east-west GW namespace. Default: auto-detect.
#   EW_SERVICE    — east-west GW Service name (default istio-eastwest).
#   EW_PORTS      — space-separated TCP ports to forward. Default: read from
#                   the Service's spec.ports (so istio-gw gets 15021 too,
#                   agentgw stops at 15012).
#   API_PUBLISH   — also publish the kind API server on <HOST_LAN_IP>:6443
#                   so peer-with.sh on the other machine can reach this
#                   cluster's kube API. Default "yes". Set "no" to skip
#                   (e.g. if you're tunnelling 6443 over SSH separately).
#   API_PORT      — port to publish the kind API on (default 6443).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOCAT_IMAGE="${SOCAT_IMAGE:-alpine/socat:latest}"
EW_NAMESPACE="${EW_NAMESPACE:-}"   # autodetect if unset
EW_SERVICE="${EW_SERVICE:-istio-eastwest}"
EW_PORTS="${EW_PORTS:-}"           # autodetect from service spec if unset
DOCKER_NETWORK="${DOCKER_NETWORK:-kind}"
API_PUBLISH="${API_PUBLISH:-yes}"
API_PORT="${API_PORT:-6443}"

# Normalize API_PUBLISH to lowercase once — ${VAR,,} is bash 4+ and macOS
# ships bash 3.2, so do it the portable way via tr.
API_PUBLISH_LC="$(printf '%s' "$API_PUBLISH" | tr '[:upper:]' '[:lower:]')"

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
  [[ -n "$n" ]] || die "cluster name required. Example: ./scripts/expose-ew-on-host.sh green"
  if [[ ! "$n" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
    die "'$n' is not a valid k8s DNS label"
  fi
}

detect_host_lan_ip() {
  local ip=""
  case "$(uname -s)" in
    Darwin)
      ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
      [[ -z "$ip" ]] && ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
      ;;
    Linux)
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      ;;
  esac
  echo "$ip"
}

container_name() {
  # Bash 3 compatible — no associative arrays.
  echo "ew-fwd-${1}-${2}"
}

# ── Args ──────────────────────────────────────────────────────────────────────

MODE="up"
if [[ "${1:-}" == "down" ]]; then
  MODE="down"
  shift
fi

NAME="${1:-}"
validate_name "$NAME"

# ── Down: stop containers ─────────────────────────────────────────────────────

if [[ "$MODE" == "down" ]]; then
  step "Stopping east-west host-side tunnels for cluster '$NAME'"
  require docker
  stopped=0
  # Include API tunnel in the teardown set.
  for PORT in $EW_PORTS "$API_PORT"; do
    CN="$(container_name "$NAME" "$PORT")"
    if docker ps -a --format '{{.Names}}' | grep -qx "$CN"; then
      docker rm -f "$CN" >/dev/null 2>&1 && {
        log_ok "stopped $CN"
        stopped=$((stopped + 1))
      }
    else
      log "skip $CN (not running)"
    fi
  done
  echo ""
  log_ok "$stopped tunnel container(s) stopped"
  exit 0
fi

# ── Up: prereqs ───────────────────────────────────────────────────────────────

step "Checking prereqs"
require docker
require kubectl
log_ok "tools present"

docker info >/dev/null 2>&1 || die "docker daemon is not reachable"
log_ok "docker daemon reachable"

# Docker network must exist (kind creates it on first cluster).
if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
  die "docker network '$DOCKER_NETWORK' not found — has kind created any cluster yet?"
fi
log_ok "docker network '$DOCKER_NETWORK' present"

CTX="kind-${NAME}"
kubectl --context "$CTX" get ns >/dev/null 2>&1 \
  || die "kube context '$CTX' not reachable — is the kind cluster up?"
log_ok "kube context $CTX reachable"

# ── Detect host LAN IP ────────────────────────────────────────────────────────

step "Detecting host LAN IP"
if [[ -z "${HOST_LAN_IP:-}" ]]; then
  HOST_LAN_IP="$(detect_host_lan_ip)"
fi
if [[ -z "$HOST_LAN_IP" ]]; then
  cat >&2 <<EOF
ERROR: could not auto-detect host LAN IP.

  Tried (macOS): ipconfig getifaddr en0 / en1
  Tried (Linux): hostname -I | awk '{print \$1}'

  Set it explicitly:
    HOST_LAN_IP=192.168.1.42 ./scripts/expose-ew-on-host.sh $NAME
EOF
  exit 1
fi
log_ok "host LAN IP: $HOST_LAN_IP"

# ── Auto-detect EW namespace if not set ───────────────────────────────────────
# Probe both known conventions: agentgw uses istio-eastwest, istio-gw uses
# istio-gateways. Pick whichever has the EW_SERVICE Service.

if [[ -z "$EW_NAMESPACE" ]]; then
  step "Auto-detecting east-west GW namespace"
  for cand in istio-eastwest istio-gateways; do
    if kubectl --context "$CTX" -n "$cand" get svc "$EW_SERVICE" >/dev/null 2>&1; then
      EW_NAMESPACE="$cand"
      log_ok "found $EW_SERVICE in namespace $EW_NAMESPACE"
      break
    fi
  done
  [[ -n "$EW_NAMESPACE" ]] || die "couldn't find Service '$EW_SERVICE' in either istio-eastwest or istio-gateways — pass EW_NAMESPACE explicitly"
fi

# ── Look up east-west GW Service ──────────────────────────────────────────────

step "Looking up east-west GW Service $EW_NAMESPACE/$EW_SERVICE"
EW_CLUSTERIP="$(kubectl --context "$CTX" -n "$EW_NAMESPACE" get svc "$EW_SERVICE" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
EW_LBIP="$(kubectl --context "$CTX" -n "$EW_NAMESPACE" get svc "$EW_SERVICE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[[ -n "$EW_CLUSTERIP" ]] || die "Service $EW_NAMESPACE/$EW_SERVICE not found in $CTX"

# Auto-detect EW_PORTS from the Service spec when not explicitly set, so the
# istio-gw lab's 15021 status port also gets forwarded automatically.
if [[ -z "$EW_PORTS" ]]; then
  EW_PORTS="$(kubectl --context "$CTX" -n "$EW_NAMESPACE" get svc "$EW_SERVICE" \
    -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}' 2>/dev/null | xargs)"
  [[ -n "$EW_PORTS" ]] || die "couldn't read spec.ports from $EW_NAMESPACE/$EW_SERVICE"
  log_ok "auto-detected ports: $EW_PORTS"
fi

# Prefer the MetalLB LB IP — it's the stable address that ztunnel + agentgateway
# advertise as the east-west endpoint. Falls back to ClusterIP if LB hasn't
# been assigned yet (kube-proxy on the kind nodes will route correctly).
TARGET_IP="${EW_LBIP:-$EW_CLUSTERIP}"
log "  ClusterIP: $EW_CLUSTERIP"
log "  LB IP:     ${EW_LBIP:-<pending>}"
log_ok "forwarding target: $TARGET_IP"

# ── Launch socat containers ───────────────────────────────────────────────────

step "Launching socat tunnels on $HOST_LAN_IP for ports: $EW_PORTS"
# Pre-pull the socat image once so each per-port run doesn't race on the pull.
docker pull --quiet "$SOCAT_IMAGE" >/dev/null

for PORT in $EW_PORTS; do
  CN="$(container_name "$NAME" "$PORT")"
  # Idempotency: if a container with the same name already exists, remove it
  # before starting (the binding rule may have changed — e.g. host LAN IP
  # rotated, or the target ClusterIP changed after a cluster rebuild).
  if docker ps -a --format '{{.Names}}' | grep -qx "$CN"; then
    log "  removing stale $CN"
    docker rm -f "$CN" >/dev/null
  fi
  docker run -d --rm \
    --name "$CN" \
    --network "$DOCKER_NETWORK" \
    -p "${HOST_LAN_IP}:${PORT}:${PORT}" \
    "$SOCAT_IMAGE" \
    "tcp-listen:${PORT},fork,reuseaddr" "tcp:${TARGET_IP}:${PORT}" >/dev/null
  log_ok "started $CN  →  ${HOST_LAN_IP}:${PORT} → ${TARGET_IP}:${PORT}"
done

# ── Optional: also republish the kind API server on the LAN ──────────────────
# Why: peer-with.sh on the OTHER machine rewrites the remote-secret's
# kubeconfig server: URL to https://<this-host-LAN-IP>:6443 so its istiod
# can read this cluster's API for service discovery. The kind control-plane
# container is named "<cluster>-control-plane" and exposes 6443 inside the
# Docker network — socat bridges that to the host's LAN IP.

if [[ "$API_PUBLISH_LC" == "yes" || "$API_PUBLISH_LC" == "true" || "$API_PUBLISH" == "1" ]]; then
  step "Republishing kind API server on $HOST_LAN_IP:$API_PORT"
  KIND_CP_CONTAINER="${NAME}-control-plane"
  if ! docker inspect "$KIND_CP_CONTAINER" >/dev/null 2>&1; then
    log "  ! container '$KIND_CP_CONTAINER' not found — is the kind cluster up?"
  else
    CN="$(container_name "$NAME" "$API_PORT")"
    if docker ps -a --format '{{.Names}}' | grep -qx "$CN"; then
      log "  removing stale $CN"
      docker rm -f "$CN" >/dev/null
    fi
    docker run -d --rm \
      --name "$CN" \
      --network "$DOCKER_NETWORK" \
      -p "${HOST_LAN_IP}:${API_PORT}:${API_PORT}" \
      "$SOCAT_IMAGE" \
      "tcp-listen:${API_PORT},fork,reuseaddr" "tcp:${KIND_CP_CONTAINER}:${API_PORT}" >/dev/null
    log_ok "started $CN  →  ${HOST_LAN_IP}:${API_PORT} → ${KIND_CP_CONTAINER}:${API_PORT}"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  East-west GW republished on host LAN — cluster '$NAME'"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Host LAN IP:    $HOST_LAN_IP"
echo "  Forwarding:     $EW_NAMESPACE/$EW_SERVICE @ $TARGET_IP"
echo ""
echo "  Peer machine endpoints (use in peer-with.sh on the OTHER host):"
for PORT in $EW_PORTS; do
  echo "    ${HOST_LAN_IP}:${PORT}   (HBONE/XDS)"
done
if [[ "$API_PUBLISH_LC" == "yes" || "$API_PUBLISH_LC" == "true" || "$API_PUBLISH" == "1" ]]; then
  echo "    ${HOST_LAN_IP}:${API_PORT}   (kind API server)"
fi
echo ""
echo "  Stop the tunnels with:"
echo "    ./scripts/expose-ew-on-host.sh down $NAME"
echo ""
echo "${YEL}  Note:${RST} the OTHER machine consumes ${HOST_LAN_IP}:15008 as the"
echo "  HBONE endpoint when invoking peer-with.sh, e.g.:"
echo "    ./scripts/peer-with.sh <local-name> /tmp/peer-bundle-${NAME}.tar.gz ${HOST_LAN_IP}:15008"
echo ""

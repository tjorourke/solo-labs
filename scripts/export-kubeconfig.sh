#!/usr/bin/env bash
# export-kubeconfig.sh — write one kubeconfig file per kind cluster, named
# after the cluster, ready to scp back to a laptop for k9s/kubectl use.
#
# Why this exists:
#   `kind` binds each cluster's API server to 127.0.0.1:<random-port> on the
#   host where Docker runs. From your laptop those ports are only reachable
#   over an SSH local-port-forward. The kubeconfig's server URL stays at
#   127.0.0.1:<port> (kind's TLS cert is only valid for 127.0.0.1, so
#   rewriting the URL to the host's LAN address breaks the handshake).
#
#   This script:
#     1. Discovers every kind cluster on this machine.
#     2. Writes one kubeconfig file per cluster, named <cluster>.yaml, into
#        an output dir (default $HOME/.kube/kind, override with -o or $OUT).
#     3. Prints the SSH -L flags + scp commands you need on your laptop.
#
# Lives at the repo root's scripts/ — works for any kind cluster on the host,
# not tied to a specific lab (agentgw, istio-gw, …).
#
# Usage on the REMOTE machine (where kind clusters live):
#   ./scripts/export-kubeconfig.sh                  # writes to ~/.kube/kind/
#   ./scripts/export-kubeconfig.sh -o /tmp/kc       # custom output dir
#
# On your LAPTOP, copy the files back + open SSH tunnels:
#   scp -r tomorourke@toms-mac-mini-2:.kube/kind ~/.kube/
#   ssh -L <port>:localhost:<port> ... tomorourke@toms-mac-mini-2   # ports from stderr
#   KUBECONFIG=~/.kube/kind/east-ag.yaml k9s

set -Eeuo pipefail

OUTDIR="${OUT:-$HOME/.kube/kind}"

usage() {
  cat <<USAGE
Usage: $0 [-o OUT_DIR]

  -o, --out DIR    Output directory for the per-cluster kubeconfig files.
                   Defaults to \$HOME/.kube/kind.
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUTDIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

log() { echo "$*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v kind >/dev/null 2>&1 || die "kind not found on this machine"

CLUSTERS=$(kind get clusters 2>/dev/null || true)
[[ -n "$CLUSTERS" ]] || die "no kind clusters found"

mkdir -p "$OUTDIR"

WRITTEN=()
PORTS=()

while IFS= read -r CLUSTER; do
  [[ -z "$CLUSTER" ]] && continue
  OUT="$OUTDIR/${CLUSTER}.yaml"
  # Suppress kind's "Set kubectl context to ..." stderr noise.
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$OUT" >/dev/null 2>&1
  PORT=$(grep -oE 'server: https://127\.0\.0\.1:[0-9]+' "$OUT" | grep -oE '[0-9]+$' | head -1)
  [[ -n "$PORT" ]] || { log "skipping $CLUSTER: couldn't determine API port"; rm -f "$OUT"; continue; }
  chmod 600 "$OUT"
  WRITTEN+=("$OUT")
  PORTS+=("$PORT")
done <<< "$CLUSTERS"

(( ${#WRITTEN[@]} > 0 )) || die "no usable kind kubeconfigs found"

# Print a per-cluster summary + the SSH tunnel & scp instructions.
HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
USER_NAME="$(id -un)"

log ""
log "════════════════════════════════════════════════════════════════════"
log "  kind kubeconfigs written:"
for i in "${!WRITTEN[@]}"; do
  log "    ${WRITTEN[$i]}   (API port ${PORTS[$i]})"
done

log ""
log "  From your LAPTOP, copy them back:"
log "    scp -r ${USER_NAME}@${HOST_SHORT}:${OUTDIR/#$HOME/\~} ~/.kube/"
log ""
log "  Open SSH tunnels for the API server ports:"
printf "    ssh" >&2
for P in "${PORTS[@]}"; do
  printf " -L %s:localhost:%s" "$P" "$P" >&2
done
printf " %s@%s\n" "$USER_NAME" "$HOST_SHORT" >&2

log ""
log "  Or persistent — add to your laptop's ~/.ssh/config:"
log "    Host $HOST_SHORT"
log "      HostName $HOST_FQDN"
log "      User $USER_NAME"
for P in "${PORTS[@]}"; do
  log "      LocalForward $P localhost:$P"
done
log "    Then: ssh $HOST_SHORT   (tunnels stay open as long as the session is)"

log ""
log "  Use a cluster from your laptop:"
log "    KUBECONFIG=\$HOME/.kube/kind/<cluster>.yaml k9s"
log "    KUBECONFIG=\$HOME/.kube/kind/<cluster>.yaml kubectl get nodes"
log ""
log "  Or merge all of them on demand:"
log "    KUBECONFIG=\$(ls \$HOME/.kube/kind/*.yaml | tr '\\\\n' ':') kubectl config get-contexts"
log "════════════════════════════════════════════════════════════════════"

#!/usr/bin/env bash
# super-quick.sh — Stand up the Solo Enterprise for Istio multicluster
# management-plane reference setup across TWO Macs, end-to-end, hands-off.
#
# What it builds (matches manual-vs-solo-mgmt-plane/index.html):
#   * Local Mac (this host): kind cluster `east-laptop` — runs the Solo
#     Enterprise mgmt plane (gloo-mesh-mgmt-server + UI + Prometheus + relay)
#     AND a workload mesh node.
#   * Remote Mac (user@host): kind cluster `west-mini` — workload-only,
#     gloo-mesh-agent connected to the local mgmt plane.
#   * Shared root CA (cacerts) — same root, per-cluster intermediates.
#   * Ambient mesh on both, east-west Gateway exposed on LAN IPs via socat
#     so HBONE 15008 + XDS 15012 are reachable across the two hosts.
#   * Solo Enterprise CRDs (installEnterpriseCrds=true) on both clusters,
#     featureGates.ConfigDistribution=true on the mgmt release.
#   * Manual `istio-remote` peer Gateway CRs with explicit LAN-routable
#     addresses (kind-on-two-Macs gap — see header comment in
#     phase_peer_gateways below for why auto-peering alone is insufficient).
#   * Bookinfo on both clusters with solo.io/service-scope=global on
#     productpage; Workspace + WorkspaceSettings + AccessPolicy on the mgmt
#     cluster, demonstrating one CR → translated AuthorizationPolicy on each
#     workload cluster.
#   * End-to-end failover verification (scale east-laptop's productpage to 0,
#     curl by hostname, expect HTTP 200 from west-mini).
#
# Usage:
#   ./scripts/super-quick.sh                                     # mgmt plane + peering only (prompts for --user / --host)
#   ./scripts/super-quick.sh --user <name> --host <host|ip>      # skip the prompt
#   ./scripts/super-quick.sh --deploy-bookinfo                   # also deploy bookinfo + AccessPolicy
#                                                        #   + run cross-cluster failover test
#   ./scripts/super-quick.sh --skip-build                        # skip phase 1 (clusters already exist)
#   ./scripts/super-quick.sh teardown                            # tear both clusters down
#
# Required (interactive prompt if not passed):
#   --user <name>        Remote SSH user
#   --host <host|ip>     Remote SSH host (mDNS or LAN IP)
#   --east-name <name>   Local kind cluster name (default mgmt-cluster)      | also: CLUSTER1=<name>
#   --west-name <name>   Remote kind cluster name (default workload-cluster) | also: CLUSTER2=<name>
#
# Chart / image source overrides (env-only):
#   GLOO_PLATFORM_NIGHTLY=true     convenience: builds oci:// chart URLs from
#                                  GLOO_PLATFORM_NIGHTLY_REGISTRY and uses the
#                                  same path for images. Requires you to ALSO
#                                  set GLOO_PLATFORM_NIGHTLY_REGISTRY (no
#                                  baked-in default URL) and probably
#                                  GLOO_PLATFORM_VERSION + _IMAGE_TAG.
#   GLOO_PLATFORM_NIGHTLY_REGISTRY base GAR path used by NIGHTLY=true
#                                  (e.g. us-central1-docker.pkg.dev/<proj>/<repo>)
#   GLOO_PLATFORM_CHART            chart ref (HTTP repo style or "oci://…")
#   GLOO_PLATFORM_CRDS_CHART       chart ref for gloo-platform-crds
#   GLOO_PLATFORM_VERSION          chart version (default 2.12.4)
#   GLOO_PLATFORM_IMAGE_REGISTRY   container-image base (e.g. us-central1-docker.pkg.dev/…)
#                                  When set: a `gar-creds` docker-registry Secret
#                                  is minted in gloo-mesh on both clusters and
#                                  wired into the chart's imagePullSecrets.
#   GLOO_PLATFORM_IMAGE_TAG        override the image tag on every pod (maps to
#                                  common.imageTag). Use when the chart version
#                                  and image tag diverge (common with nightlies).
#
# Prereqs (both Macs):
#   - docker, kind, kubectl, helm, istioctl (Solo distro), meshctl
#   - bash 4+, openssl, jq, socat-in-Docker (alpine/socat:latest pulled)
#   - SSH key-based auth from this Mac → <user>@<host> (no password prompt)
#   - Same SECRETS_FILE on both: exports SOLO_LICENSE_KEY (== gloo-mesh-gateway
#     license JWT with lt:ent) and GLOO_MESH_LICENSE_KEY.
#   - LAN connectivity between the two Macs (both on same /24, no firewall on
#     TCP 6443 / 15008 / 15012 / 9900).
#
# Idempotency: every phase checks current state before doing work. Safe to
# re-run; safe to interrupt mid-way and re-run.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # this scripts/ dir
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"                    # solo-labs repo root
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Add the standard tool dirs for istioctl/meshctl (Solo's installers drop them
# here, but they don't always end up on PATH for non-interactive shells).
# build_path_prefix probes each candidate so the same line works on macOS
# (with /opt/homebrew) and Linux (without).
export PATH="$(build_path_prefix):$PATH"

# Remote scratch dir — resolved to an absolute path at phase 1 (scp doesn't
# expand $HOME; only on_remote does, because it goes through a shell).
REMOTE_SCRATCH=""

# Remote $HOME + the remote-side translation of SECRETS_FILE. Filled in by
# require_prereqs after the ssh-reachability check. The two Macs have
# different usernames so absolute paths under /Users/<user>/ don't transfer
# 1:1 — we substitute local $HOME → remote $HOME instead.
REMOTE_HOME=""
REMOTE_SECRETS_FILE=""

# ─── parameters ──────────────────────────────────────────────────────────────
USER_REMOTE=""
HOST_REMOTE=""
# Cluster names: --east-name/--west-name flags override; CLUSTER1/CLUSTER2 env
# vars are the non-interactive fallback; an interactive prompt picks up the
# default ("mgmt-cluster"/"workload-cluster") if none of those are set.
EAST_NAME="${CLUSTER1:-}"
WEST_NAME="${CLUSTER2:-}"
GLOO_PLATFORM_VERSION="${GLOO_PLATFORM_VERSION:-2.12.4}"
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.2-solo}"

# ─── chart / image source overrides ──────────────────────────────────────────
# Mirrors AGW_REGISTRY / AGW_IMAGE_REGISTRY in agentgw-multi-cluster-kind.
# Default chart source is the public Helm repo. Override either individually
# (GLOO_PLATFORM_CHART etc.) or via GLOO_PLATFORM_NIGHTLY=true below.
GLOO_PLATFORM_CHART="${GLOO_PLATFORM_CHART:-}"
GLOO_PLATFORM_CRDS_CHART="${GLOO_PLATFORM_CRDS_CHART:-}"
GLOO_PLATFORM_IMAGE_REGISTRY="${GLOO_PLATFORM_IMAGE_REGISTRY:-}"
# When set, all pod images use this tag instead of the chart's appVersion.
# Useful when chart and image tags diverge (e.g. nightly chart `v…-2026-05-15`
# but image only built at `…-2026-05-14`). Maps to `common.imageTag`.
GLOO_PLATFORM_IMAGE_TAG="${GLOO_PLATFORM_IMAGE_TAG:-}"

# GLOO_PLATFORM_NIGHTLY=true: convenience switch that constructs OCI chart
# URLs from a single base registry path, mirroring AGW_NIGHTLY in
# agentgw-multi-cluster-kind/scripts/quick.sh. Unlike AGW_NIGHTLY, no
# canonical default URL is baked in — Solo's gloo-platform nightlies don't
# live at a single stable public path, so the user supplies the base via
# GLOO_PLATFORM_NIGHTLY_REGISTRY. Chart paths are constructed as
#   oci://<registry>/charts/gloo-platform
#   oci://<registry>/charts/gloo-platform-crds
# Override GLOO_PLATFORM_CHART / _CRDS_CHART directly if Solo's bucket uses
# different chart names. Set GLOO_PLATFORM_VERSION to the nightly chart tag.
if [[ "${GLOO_PLATFORM_NIGHTLY:-false}" == "true" ]]; then
  [[ -n "${GLOO_PLATFORM_NIGHTLY_REGISTRY:-}" ]] \
    || die "GLOO_PLATFORM_NIGHTLY=true requires GLOO_PLATFORM_NIGHTLY_REGISTRY=<host>/<path> (e.g. us-central1-docker.pkg.dev/<proj>/<repo>). Ask Solo for the gloo-platform nightly registry URL."
  GLOO_PLATFORM_CHART="${GLOO_PLATFORM_CHART:-oci://${GLOO_PLATFORM_NIGHTLY_REGISTRY}/charts/gloo-platform}"
  GLOO_PLATFORM_CRDS_CHART="${GLOO_PLATFORM_CRDS_CHART:-oci://${GLOO_PLATFORM_NIGHTLY_REGISTRY}/charts/gloo-platform-crds}"
  GLOO_PLATFORM_IMAGE_REGISTRY="${GLOO_PLATFORM_IMAGE_REGISTRY:-$GLOO_PLATFORM_NIGHTLY_REGISTRY}"
  [[ "$GLOO_PLATFORM_VERSION" == "2.12.4" ]] \
    && warn "GLOO_PLATFORM_NIGHTLY=true but GLOO_PLATFORM_VERSION is still the public default '2.12.4' — set it to the nightly chart tag (e.g. v2026.X.X-nightly-YYYY-MM-DD)"
fi

# Final fallback: anything not overridden lands on the public Helm repo.
GLOO_PLATFORM_CHART="${GLOO_PLATFORM_CHART:-gloo-platform/gloo-platform}"
GLOO_PLATFORM_CRDS_CHART="${GLOO_PLATFORM_CRDS_CHART:-gloo-platform/gloo-platform-crds}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
QUICK_SINGLE_SCRIPT="${QUICK_SINGLE_SCRIPT:-agentgw-multi-cluster-kind/scripts/quick-single.sh}"
EXPOSE_SCRIPT="${EXPOSE_SCRIPT:-scripts/expose-ew-on-host.sh}"

SKIP_BUILD=0
DEPLOY_BOOKINFO=0
ACTION="up"

# Non-interactive SSH sessions don't source the remote's ~/.bashrc / ~/.zshrc,
# so kind, kubectl, helm, istioctl, meshctl may not be on PATH. The snippet
# from remote_path_prefix() probes each candidate dir at exec time on the
# remote — works for both macOS (with /opt/homebrew) and Linux remotes.
REMOTE_PATH_PREFIX="$(remote_path_prefix)"

# ─── arg parsing ─────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)         USER_REMOTE="$2"; shift 2 ;;
    --host)         HOST_REMOTE="$2"; shift 2 ;;
    --east-name)    EAST_NAME="$2";   shift 2 ;;
    --west-name)    WEST_NAME="$2";   shift 2 ;;
    --skip-build)   SKIP_BUILD=1;     shift   ;;
    --deploy-bookinfo) DEPLOY_BOOKINFO=1; shift ;;
    teardown)       ACTION="teardown"; shift  ;;
    -h|--help)      usage 0 ;;
    -*)             die "unknown flag: $1" ;;
    *)              die "unexpected positional: $1" ;;
  esac
done

# Prompt for --user / --host if not passed. Fail fast (rather than hang) when
# stdin isn't a TTY — e.g. CI or `./scripts/super-quick.sh </dev/null`.
if [[ -z "$USER_REMOTE" ]]; then
  if [[ -t 0 ]]; then read -r -p "Remote SSH user: " USER_REMOTE
  else die "remote SSH user required — pass --user <name>"
  fi
fi
if [[ -z "$HOST_REMOTE" ]]; then
  if [[ -t 0 ]]; then read -r -p "Remote SSH host (mDNS name or LAN IP): " HOST_REMOTE
  else die "remote SSH host required — pass --host <host>"
  fi
fi
[[ -n "$USER_REMOTE" && -n "$HOST_REMOTE" ]] || die "both --user and --host are required"

# Cluster names — same prompt pattern, but with a default the user can accept
# by just hitting Enter. Non-interactive runs without overrides get the
# defaults silently.
if [[ -z "$EAST_NAME" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Local (mgmt) cluster name [mgmt-cluster]: " EAST_NAME
    EAST_NAME="${EAST_NAME:-mgmt-cluster}"
  else
    EAST_NAME="mgmt-cluster"
  fi
fi
if [[ -z "$WEST_NAME" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Remote (workload) cluster name [workload-cluster]: " WEST_NAME
    WEST_NAME="${WEST_NAME:-workload-cluster}"
  else
    WEST_NAME="workload-cluster"
  fi
fi

REMOTE="${USER_REMOTE}@${HOST_REMOTE}"

# ─── helpers ─────────────────────────────────────────────────────────────────
on_remote() { ssh_q "$REMOTE" "$REMOTE_PATH_PREFIX $*"; }

# LAN-IP detection is in lib.sh as `detect_lan_ip` (works on macOS + Linux).
# For the remote host, inline a uname-switch over SSH so we don't depend on
# lib.sh being already sourced there.
detect_remote_lan_ip() {
  on_remote 'case "$(uname -s)" in
    Darwin) ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ipconfig getifaddr en6 2>/dev/null ;;
    Linux)  hostname -I 2>/dev/null | awk "{print \$1}" ;;
  esac'
}

wait_until() {
  local desc="$1" timeout="${2:-300}" interval="${3:-5}"; shift 3
  local elapsed=0
  while (( elapsed < timeout )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "$interval"; elapsed=$(( elapsed + interval ))
  done
  die "timeout waiting for $desc after ${timeout}s"
}

# ─── precondition checks ─────────────────────────────────────────────────────
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH — install it first"; }

require_secrets() {
  [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE not found at $SECRETS_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  [[ -n "${SOLO_LICENSE_KEY:-}" ]]      || die "SOLO_LICENSE_KEY not exported by $SECRETS_FILE"
  [[ -n "${GLOO_MESH_LICENSE_KEY:-}" ]] || die "GLOO_MESH_LICENSE_KEY not exported by $SECRETS_FILE"
  # Sanity: license is for the right product (lt:ent + product:gloo-mesh-gateway).
  # Gloo Mesh license JWTs are 2-part (payload.signature), so the payload is
  # field 1, not the middle chunk of a standard 3-part JWT.
  local payload p_padded
  payload=$(printf '%s' "$GLOO_MESH_LICENSE_KEY" | cut -d. -f1 | tr '_-' '/+')
  # Pad to multiple of 4 chars so base64 -d doesn't complain about the length.
  local mod=$(( ${#payload} % 4 ))
  if   (( mod == 2 )); then p_padded="$payload=="
  elif (( mod == 3 )); then p_padded="$payload="
  else                      p_padded="$payload"; fi
  if printf '%s' "$p_padded" | base64 -d 2>/dev/null | grep -q '"lt":"ent"'; then :
  else warn "GLOO_MESH_LICENSE_KEY does not decode as lt:ent — MultiCluster may stay locked"; fi
}

require_prereqs() {
  log "checking local prereqs"
  for bin in docker kind kubectl helm istioctl jq; do require "$bin"; done
  log "checking SSH reach to $REMOTE"
  ssh_reachable "$REMOTE" || die "can't ssh to $REMOTE — fix key auth first"

  # Resolve remote $HOME and translate the local SECRETS_FILE path to the
  # remote-side path. The two hosts have different usernames, so paths under
  # /Users/<local-user>/ aren't valid on the remote — substitute the remote
  # $HOME instead. Absolute paths that don't live under $HOME are assumed
  # identical on both machines (e.g. /etc/...).
  REMOTE_HOME="$(on_remote 'printf %s "$HOME"')"
  [[ -n "$REMOTE_HOME" ]] || die "could not resolve \$HOME on $REMOTE"
  if [[ "$SECRETS_FILE" == "$HOME/"* ]]; then
    REMOTE_SECRETS_FILE="$REMOTE_HOME/${SECRETS_FILE#$HOME/}"
  else
    REMOTE_SECRETS_FILE="$SECRETS_FILE"
  fi

  log "checking remote prereqs"
  on_remote 'for b in docker kind kubectl helm istioctl jq; do command -v $b >/dev/null 2>&1 || { echo "MISSING:$b"; exit 1; }; done; echo "OK"' \
    | grep -q '^OK$' || die "remote is missing one of docker/kind/kubectl/helm/istioctl/jq"
  on_remote "test -f $REMOTE_SECRETS_FILE" \
    || die "$REMOTE_SECRETS_FILE missing on $REMOTE — scp it across (or set SECRETS_FILE=<remote-abs-path>)"
  ok "prereqs OK"
}

# ─── phase 1: build both clusters with shared root CA ────────────────────────
phase_build_clusters() {
  if (( SKIP_BUILD )); then log "phase 1 (build) skipped via --skip-build"; return; fi

  log "── phase 1: build kind clusters with shared root CA ──"

  local quick_single="$REPO_ROOT/$QUICK_SINGLE_SCRIPT"
  [[ -x "$quick_single" ]] || die "quick-single.sh not found at $quick_single"
  local quick_single_subpath="${QUICK_SINGLE_SCRIPT%/scripts/*}"   # e.g. agentgw-multi-cluster-kind
  local certs_dir; certs_dir="$(cd "$(dirname "$quick_single")/.." && pwd)/certs"

  # 1a: local east cluster (quick-single generates root-ca.{crt,key} if absent).
  if kind get clusters 2>/dev/null | grep -qx "$EAST_NAME"; then
    ok "kind cluster $EAST_NAME already exists"
  else
    log "building local kind cluster $EAST_NAME (this takes ~3-4 min)"
    ( cd "$REPO_ROOT" && SECRETS_FILE="$SECRETS_FILE" "$quick_single" "$EAST_NAME" )
  fi

  # 1b: ship the install scripts + shared root CA to the remote. We use a
  # well-known scratch dir (REMOTE_SCRATCH on the remote) so the remote
  # doesn't need a matching repo layout to ours — this is what makes the
  # script portable across host setups. Resolve the absolute path now since
  # scp doesn't expand $HOME (only shell calls via on_remote do).
  [[ -f "$certs_dir/root-ca.crt" && -f "$certs_dir/root-ca.key" ]] \
    || die "root CA missing at $certs_dir after east-laptop build — quick-single failed?"
  log "syncing scripts + shared root CA → $REMOTE:$REMOTE_SCRATCH"
  on_remote "mkdir -p $REMOTE_SCRATCH/$quick_single_subpath/scripts \
                       $REMOTE_SCRATCH/$quick_single_subpath/certs \
                       $REMOTE_SCRATCH/scripts"
  # Install scripts (quick-single + lib.sh + expose-ew).
  scp_q "$quick_single" "$REMOTE:$REMOTE_SCRATCH/$quick_single_subpath/scripts/quick-single.sh" >/dev/null
  scp_q "$SCRIPT_DIR/lib.sh" "$REMOTE:$REMOTE_SCRATCH/scripts/lib.sh" >/dev/null
  scp_q "$SCRIPT_DIR/expose-ew-on-host.sh" "$REMOTE:$REMOTE_SCRATCH/scripts/expose-ew-on-host.sh" >/dev/null
  scp_q "$SCRIPT_DIR/export-kubeconfig.sh" "$REMOTE:$REMOTE_SCRATCH/scripts/export-kubeconfig.sh" 2>/dev/null || true
  # Shared root CA so the second cluster's intermediate is signed by the same root.
  scp_q "$certs_dir/root-ca.crt" "$certs_dir/root-ca.key" \
        "$REMOTE:$REMOTE_SCRATCH/$quick_single_subpath/certs/" >/dev/null
  on_remote "chmod +x $REMOTE_SCRATCH/$quick_single_subpath/scripts/quick-single.sh $REMOTE_SCRATCH/scripts/*.sh"

  # 1c: remote west cluster — invoke the synced quick-single.sh.
  if on_remote "kind get clusters 2>/dev/null | grep -qx $WEST_NAME"; then
    ok "kind cluster $WEST_NAME already exists on $REMOTE"
  else
    log "building remote kind cluster $WEST_NAME on $REMOTE (~3-4 min)"
    on_remote "cd $REMOTE_SCRATCH/$quick_single_subpath && SECRETS_FILE=$REMOTE_SECRETS_FILE bash scripts/quick-single.sh $WEST_NAME"
  fi

  ok "both kind clusters up with shared root CA"
}

# ─── phase 2: uninstall agentgateway (mgmt-plane lab doesn't use it; conflict
# on authconfigs.extauth.solo.io + ratelimitconfigs.ratelimit.solo.io between
# enterprise-agentgateway-crds and gloo-platform-crds when installEnterpriseCrds
# is true. Solo's Ambient Multi-Cluster Interoperability use-case uses
# installEnterpriseCrds=false; we need =true here for AccessPolicy + the
# featureGates.ConfigDistribution beta. Uninstalling agentgateway frees the
# conflicting CRDs cleanly.) ─────────────────────────────────────────────────
phase_uninstall_agw() {
  log "── phase 2: uninstall agentgateway from both clusters ──"
  uninstall_agw_local()  { helm --kube-context="kind-$EAST_NAME" -n agentgateway-system "$@" 2>/dev/null; }
  uninstall_agw_remote() { on_remote "helm --kube-context=kind-$WEST_NAME -n agentgateway-system $*"; }

  for pair in "local:$EAST_NAME" "remote:$WEST_NAME"; do
    local side="${pair%%:*}" name="${pair##*:}" ctx="kind-${pair##*:}"
    local present
    if [[ "$side" == "local" ]]; then
      present=$(helm --kube-context="$ctx" -n agentgateway-system ls -q 2>/dev/null | tr '\n' ' ')
    else
      present=$(on_remote "helm --kube-context=$ctx -n agentgateway-system ls -q 2>/dev/null | tr '\n' ' '")
    fi
    if [[ -z "${present// }" ]]; then ok "  $ctx: agentgateway absent"; continue; fi
    for rel in enterprise-agentgateway agentgateway-crds; do
      [[ " $present " == *" $rel "* ]] || continue
      log "  $ctx: uninstalling $rel"
      if [[ "$side" == "local" ]]; then
        helm --kube-context="$ctx" -n agentgateway-system uninstall "$rel" >/dev/null 2>&1 || true
      else
        on_remote "helm --kube-context=$ctx -n agentgateway-system uninstall $rel" >/dev/null 2>&1 || true
      fi
    done
    if [[ "$side" == "local" ]]; then
      kubectl --context="$ctx" delete ns agentgateway-system --wait=false >/dev/null 2>&1 || true
    else
      on_remote "kubectl --context=$ctx delete ns agentgateway-system --wait=false" >/dev/null 2>&1 || true
    fi
    ok "  $ctx: agentgateway removed"
  done
}

# ─── phase 3: expose east-west GW on LAN of each host via socat ──────────────
phase_expose_lan() {
  log "── phase 3: expose east-west GW on each host's LAN IP ──"
  log "  local ($EAST_NAME)"
  ( cd "$REPO_ROOT" && "$REPO_ROOT/$EXPOSE_SCRIPT" "$EAST_NAME" ) >&2
  log "  remote ($WEST_NAME) — using $REMOTE_SCRATCH/scripts/expose-ew-on-host.sh"
  on_remote "cd $REMOTE_SCRATCH && bash scripts/expose-ew-on-host.sh $WEST_NAME" >&2
  EAST_LAN_IP="$(detect_lan_ip)"
  WEST_LAN_IP="$(detect_remote_lan_ip)"
  [[ -n "$EAST_LAN_IP" && -n "$WEST_LAN_IP" ]] \
    || die "missing LAN IPs (east=$EAST_LAN_IP west=$WEST_LAN_IP)"
  ok "east-laptop reachable at $EAST_LAN_IP, west-mini at $WEST_LAN_IP"
}

# ─── phase 4: install gloo-platform CRDs + mgmt-plane on east-laptop ─────────
phase_install_mgmt() {
  log "── phase 4: install Solo Enterprise mgmt plane on $EAST_NAME ──"
  log "  chart: $GLOO_PLATFORM_CHART  version: $GLOO_PLATFORM_VERSION"
  [[ -n "$GLOO_PLATFORM_IMAGE_REGISTRY" ]] && log "  imageRegistry: $GLOO_PLATFORM_IMAGE_REGISTRY"

  # Chart source: OCI requires `helm registry login`; HTTP repo uses `helm repo add`.
  if [[ "$GLOO_PLATFORM_CHART" == oci://* ]]; then
    helm_oci_login "$(oci_host "$GLOO_PLATFORM_CHART")"
  else
    helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts >/dev/null 2>&1 || true
    helm repo update gloo-platform >/dev/null
  fi

  # If pulling images from a private registry, kind nodes have no creds. Mint
  # a docker-registry Secret in gloo-mesh containing the gcloud access token
  # so the chart's imagePullSecrets binding works. Token expires ~1h — fine
  # for install; pod restarts after that will need the secret refreshed.
  GLOO_PLATFORM_IMAGE_TOKEN=""   # exported so phase_install_agent can re-use
  if [[ -n "$GLOO_PLATFORM_IMAGE_REGISTRY" ]]; then
    local img_host="${GLOO_PLATFORM_IMAGE_REGISTRY%%/*}"
    ensure_gar_auth "$img_host"
    GLOO_PLATFORM_IMAGE_TOKEN="$(gcloud auth print-access-token)"
    kubectl --context="kind-$EAST_NAME" create ns gloo-mesh --dry-run=client -o yaml \
      | kubectl --context="kind-$EAST_NAME" apply -f - >/dev/null
    kubectl --context="kind-$EAST_NAME" -n gloo-mesh create secret docker-registry gar-creds \
      --docker-server="$img_host" \
      --docker-username=oauth2accesstoken \
      --docker-password="$GLOO_PLATFORM_IMAGE_TOKEN" \
      --dry-run=client -o yaml \
      | kubectl --context="kind-$EAST_NAME" apply -f - >/dev/null
    log "  gar-creds image-pull secret created in gloo-mesh"
  fi

  # 4a: CRDs with enterprise bundle + ConfigDistribution beta. The flag is
  # required for the mgmt server to cross-distribute peer Gateway info between
  # workload clusters. Note: in kind-on-two-Macs auto-distribution still picks
  # the Docker-bridge LoadBalancer IP (not cross-host routable) — phase 8
  # supplements with manual peer Gateways that point at LAN IPs.
  log "  installing gloo-platform-crds on $EAST_NAME (installEnterpriseCrds=true, ConfigDistribution=true)"
  helm upgrade -i gloo-platform-crds "$GLOO_PLATFORM_CRDS_CHART" \
    --kube-context="kind-$EAST_NAME" -n gloo-mesh --create-namespace \
    --version "$GLOO_PLATFORM_VERSION" \
    --set installEnterpriseCrds=true \
    --set featureGates.ConfigDistribution=true >/dev/null

  # 4b: mgmt + agent (single-cluster profile equivalent) — relay TLS secrets
  # are auto-generated by the chart's cert-gen job on first install; do NOT
  # re-helm-install across runs (it can desync the cert chain across the
  # relay-*-tls-secret family, breaking the agent handshake. The fix is to
  # uninstall cleanly and reinstall — same as we'd do in production).
  local values_file; values_file="$(mktemp -t super-quick-mgmt-values.XXXXXX)"
  cat >"$values_file" <<EOF
common:
  cluster: $EAST_NAME
EOF
  if [[ -n "$GLOO_PLATFORM_IMAGE_REGISTRY" ]]; then
    cat >>"$values_file" <<EOF
  imageRegistry: $GLOO_PLATFORM_IMAGE_REGISTRY
  imagePullSecrets:
    - name: gar-creds
EOF
  fi
  if [[ -n "$GLOO_PLATFORM_IMAGE_TAG" ]]; then
    cat >>"$values_file" <<EOF
  imageTag: $GLOO_PLATFORM_IMAGE_TAG
EOF
  fi
  cat >>"$values_file" <<EOF
featureGates:
  ConfigDistribution: true
glooAgent:
  enabled: true
  runAsSidecar: true
  relay:
    serverAddress: gloo-mesh-mgmt-server.gloo-mesh:9900
glooAnalyzer: { enabled: true }
glooInsightsEngine: { enabled: true }
glooMgmtServer:
  enabled: true
  registerCluster: true
  policyApis:
    enabled: true
glooUi: { enabled: true }
installEnterpriseCrds: true
prometheus: { enabled: true }
redis:
  deployment: { enabled: true }
telemetryCollector: { enabled: true }
telemetryGateway: { enabled: true }
EOF

  if helm --kube-context="kind-$EAST_NAME" -n gloo-mesh ls -q 2>/dev/null | grep -qx gloo-platform; then
    log "  upgrading existing gloo-platform release"
    helm upgrade gloo-platform "$GLOO_PLATFORM_CHART" \
      --kube-context="kind-$EAST_NAME" -n gloo-mesh \
      --version "$GLOO_PLATFORM_VERSION" -f "$values_file" \
      --set licensing.glooMeshLicenseKey="$GLOO_MESH_LICENSE_KEY" >/dev/null
  else
    log "  installing gloo-platform mgmt+agent (waits ~2min for cert-gen job + relay TLS)"
    helm install gloo-platform "$GLOO_PLATFORM_CHART" \
      --kube-context="kind-$EAST_NAME" -n gloo-mesh \
      --version "$GLOO_PLATFORM_VERSION" -f "$values_file" \
      --set licensing.glooMeshLicenseKey="$GLOO_MESH_LICENSE_KEY" >/dev/null
  fi
  rm -f "$values_file"

  # 4c: wait for mgmt-server + the full relay-*-tls-secret family (the agent
  # handshake fails if any of these is missing or out-of-sync with peers).
  wait_until "mgmt-server ready" 240 5 \
    kubectl --context="kind-$EAST_NAME" -n gloo-mesh wait --for=condition=Available deploy/gloo-mesh-mgmt-server --timeout=5s
  for s in relay-root-tls-secret relay-server-tls-secret relay-client-tls-secret \
           relay-tls-signing-secret relay-identity-token-secret; do
    wait_until "$s" 120 3 \
      kubectl --context="kind-$EAST_NAME" -n gloo-mesh get secret "$s"
  done
  ok "  mgmt plane ready, relay TLS family present"

  # 4d: patch mgmt-server Service to LoadBalancer so the remote agent can
  # dial it across the LAN (the chart's default is ClusterIP, only reachable
  # in-cluster — fine on a single cluster, not on two physical Macs).
  local svc_type
  svc_type=$(kubectl --context="kind-$EAST_NAME" -n gloo-mesh get svc gloo-mesh-mgmt-server -o jsonpath='{.spec.type}')
  if [[ "$svc_type" != "LoadBalancer" ]]; then
    log "  patching mgmt-server Service: ClusterIP → LoadBalancer"
    kubectl --context="kind-$EAST_NAME" -n gloo-mesh patch svc gloo-mesh-mgmt-server \
      -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null
  fi
  wait_until "mgmt-server LB IP" 60 3 \
    bash -c "kubectl --context=kind-$EAST_NAME -n gloo-mesh get svc gloo-mesh-mgmt-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q '\\.'"
  MGMT_LB_IP="$(kubectl --context="kind-$EAST_NAME" -n gloo-mesh get svc gloo-mesh-mgmt-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

  # 4e: socat tunnel for mgmt-server relay (port 9900) on the LAN. The
  # expose-ew-on-host.sh helper handles east-west GW + kind-API but doesn't
  # know about mgmt-server, so we add this hop inline. ALWAYS rebuild the
  # container against the freshly-read $MGMT_LB_IP — MetalLB may have
  # assigned a different IP on this install vs a previous run, and a stale
  # container forwarding to an old IP silently breaks the agent handshake.
  local tunnel_name="ew-fwd-$EAST_NAME-9900"
  log "  rebuilding mgmt-server LAN tunnel: $EAST_LAN_IP:9900 → $MGMT_LB_IP:9900"
  docker rm -f "$tunnel_name" >/dev/null 2>&1 || true
  # Also remove any tunnel from earlier sessions that may be holding the host
  # port under a different name (relay-fwd-9900 was the manual-bootstrap name).
  docker ps -a --format '{{.Names}}' \
    | grep -E '^(relay|ew)-fwd.*9900' \
    | grep -v "^$tunnel_name\$" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker run -d --name "$tunnel_name" --restart=unless-stopped \
    --network kind -p "$EAST_LAN_IP:9900:9900/tcp" \
    alpine/socat:latest \
    TCP-LISTEN:9900,fork,reuseaddr "TCP:$MGMT_LB_IP:9900" >/dev/null
  ok "  mgmt-server reachable at $MGMT_LB_IP (kind bridge), $EAST_LAN_IP:9900 (LAN tunnel)"
}

# ─── phase 5: install gloo-platform CRDs + agent on west-mini ────────────────
phase_install_agent() {
  log "── phase 5: install gloo-platform agent on $WEST_NAME ──"

  # 5a: cross-apply relay TLS to west-mini (chart's bootstrap path expects
  # the agent to find relay-root-tls-secret + relay-client-tls-secret +
  # relay-identity-token-secret in its local gloo-mesh ns).
  log "  bootstrapping relay TLS for $WEST_NAME (root cert + per-cluster client cert + identity token)"
  local tmpdir; tmpdir="$(mktemp -d -t super-quick-relay.XXXXXX)"

  # 1) relay-root-tls-secret: cluster-agnostic CA cert chain — safe to copy verbatim.
  # 2) relay-identity-token-secret: bearer token validated by mgmt-server — copied verbatim.
  for s in relay-root-tls-secret relay-identity-token-secret; do
    kubectl --context="kind-$EAST_NAME" -n gloo-mesh get secret "$s" -o yaml \
      | grep -vE '^(  uid:|  resourceVersion:|  creationTimestamp:|  selfLink:|  generation:|  namespace:|  ownerReferences:|  managedFields:)' \
      | awk '/^metadata:/{print; print "  namespace: gloo-mesh"; next} {print}' \
      > "$tmpdir/$s.yaml"
  done

  # 3) relay-client-tls-secret: must have CN=$WEST_NAME so mgmt-server identifies
  # the cluster correctly. The east-laptop secret has CN=east-laptop hardcoded
  # by the cert-gen Job — if we copied it, the mgmt-server's mTLS handshake
  # would see CN=east-laptop and route west-mini's inventory back into
  # east-laptop's cluster bucket (Workspace would see only 1 cluster, the
  # AccessPolicy translation never reaches the actual west-mini cluster).
  # Mint a fresh client cert signed by relay-tls-signing-secret (the same
  # CA that meshctl cluster register uses internally).
  kubectl --context="kind-$EAST_NAME" -n gloo-mesh get secret relay-tls-signing-secret \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmpdir/signing-ca.crt"
  kubectl --context="kind-$EAST_NAME" -n gloo-mesh get secret relay-tls-signing-secret \
    -o jsonpath='{.data.tls\.key}' | base64 -d > "$tmpdir/signing-ca.key"
  openssl genrsa -out "$tmpdir/client.key" 2048 2>/dev/null
  openssl req -new -key "$tmpdir/client.key" -out "$tmpdir/client.csr" \
    -subj "/CN=$WEST_NAME" 2>/dev/null
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=clientAuth\n' "$WEST_NAME" > "$tmpdir/san.cnf"
  openssl x509 -req -in "$tmpdir/client.csr" \
    -CA "$tmpdir/signing-ca.crt" -CAkey "$tmpdir/signing-ca.key" -CAcreateserial \
    -out "$tmpdir/client.crt" -days 3650 -sha256 -extfile "$tmpdir/san.cnf" 2>/dev/null
  # Build the per-cluster relay-client-tls-secret with the freshly-minted cert.
  TLS_CRT=$(base64 < "$tmpdir/client.crt" | tr -d '\n')
  TLS_KEY=$(base64 < "$tmpdir/client.key" | tr -d '\n')
  CA_CRT=$(base64 < "$tmpdir/signing-ca.crt" | tr -d '\n')
  cat > "$tmpdir/relay-client-tls-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: relay-client-tls-secret
  namespace: gloo-mesh
data:
  tls.crt: $TLS_CRT
  tls.key: $TLS_KEY
  ca.crt:  $CA_CRT
EOF

  scp_q "$tmpdir"/*.yaml "$REMOTE:/tmp/" >/dev/null
  on_remote "kubectl --context=kind-$WEST_NAME create ns gloo-mesh 2>/dev/null || true; \
             for f in /tmp/relay-root-tls-secret.yaml /tmp/relay-client-tls-secret.yaml /tmp/relay-identity-token-secret.yaml; do \
               kubectl --context=kind-$WEST_NAME -n gloo-mesh apply -f \$f; done" >/dev/null
  rm -rf "$tmpdir"
  ok "  relay TLS bootstrapped (per-cluster client cert CN=$WEST_NAME)"

  # 5b: CRDs on workload cluster (enterprise CRDs required for ConfigDistribution
  # to push KubernetesCluster / AccessPolicy translations to this agent).
  # If the chart lives in OCI, log helm into the registry on the remote using
  # the gcloud token from the local Mac (no gcloud install needed on the mini).
  if [[ "$GLOO_PLATFORM_CRDS_CHART" == oci://* ]]; then
    local crds_host; crds_host="$(oci_host "$GLOO_PLATFORM_CRDS_CHART")"
    log "  remote helm registry login → $crds_host"
    local crds_token; crds_token="$(gcloud auth print-access-token)"
    on_remote "echo '$crds_token' | helm registry login $crds_host -u oauth2accesstoken --password-stdin >/dev/null"
  fi
  # If pulling images from a private registry, mint the same gar-creds secret
  # in the workload cluster's gloo-mesh ns so chart imagePullSecrets resolve.
  if [[ -n "$GLOO_PLATFORM_IMAGE_REGISTRY" ]]; then
    local img_host="${GLOO_PLATFORM_IMAGE_REGISTRY%%/*}"
    local img_token="${GLOO_PLATFORM_IMAGE_TOKEN:-$(gcloud auth print-access-token)}"
    on_remote "kubectl --context=kind-$WEST_NAME -n gloo-mesh create secret docker-registry gar-creds \
      --docker-server=$img_host \
      --docker-username=oauth2accesstoken \
      --docker-password='$img_token' \
      --dry-run=client -o yaml | kubectl --context=kind-$WEST_NAME apply -f -" >/dev/null
    log "  gar-creds image-pull secret created on $WEST_NAME"
  fi
  log "  installing gloo-platform-crds on $WEST_NAME (installEnterpriseCrds=true)"
  if [[ "$GLOO_PLATFORM_CRDS_CHART" == oci://* ]]; then
    on_remote "helm upgrade -i gloo-platform-crds $GLOO_PLATFORM_CRDS_CHART \
                 --kube-context=kind-$WEST_NAME -n gloo-mesh --create-namespace \
                 --version $GLOO_PLATFORM_VERSION \
                 --set installEnterpriseCrds=true" >/dev/null
  else
    on_remote "helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts >/dev/null 2>&1 || true; \
               helm repo update gloo-platform >/dev/null; \
               helm upgrade -i gloo-platform-crds $GLOO_PLATFORM_CRDS_CHART \
                 --kube-context=kind-$WEST_NAME -n gloo-mesh --create-namespace \
                 --version $GLOO_PLATFORM_VERSION \
                 --set installEnterpriseCrds=true" >/dev/null
  fi

  # 5c: agent values pointing at the LAN-exposed mgmt-server (socat at
  # $EAST_LAN_IP:9900 forwards to the LoadBalancer set up in phase 4d).
  local agent_values; agent_values="$(mktemp -t super-quick-agent-values.XXXXXX)"
  cat >"$agent_values" <<EOF
common:
  cluster: $WEST_NAME
EOF
  if [[ -n "$GLOO_PLATFORM_IMAGE_REGISTRY" ]]; then
    cat >>"$agent_values" <<EOF
  imageRegistry: $GLOO_PLATFORM_IMAGE_REGISTRY
  imagePullSecrets:
    - name: gar-creds
EOF
  fi
  if [[ -n "$GLOO_PLATFORM_IMAGE_TAG" ]]; then
    cat >>"$agent_values" <<EOF
  imageTag: $GLOO_PLATFORM_IMAGE_TAG
EOF
  fi
  cat >>"$agent_values" <<EOF
glooAgent:
  enabled: true
  insecure: false
  relay:
    serverAddress: $EAST_LAN_IP:9900
    rootTlsSecret:        { name: relay-root-tls-secret,        namespace: gloo-mesh }
    clientTlsSecret:      { name: relay-client-tls-secret,      namespace: gloo-mesh }
    tokenSecret:          { name: relay-identity-token-secret,  namespace: gloo-mesh, key: token }
glooAnalyzer: { enabled: true }
telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: gloo-telemetry-gateway.gloo-mesh:4317
telemetryCollectorCustomization:
  skipVerify: true
EOF
  scp_q "$agent_values" "$REMOTE:/tmp/agent-values.yaml" >/dev/null
  rm -f "$agent_values"

  # Always source the SECRETS_FILE on the remote — non-interactive SSH doesn't
  # source ~/.zshrc, so GLOO_MESH_LICENSE_KEY isn't otherwise in scope there.
  on_remote ". $REMOTE_SECRETS_FILE; helm upgrade -i gloo-platform $GLOO_PLATFORM_CHART \
              --kube-context=kind-$WEST_NAME -n gloo-mesh \
              --version $GLOO_PLATFORM_VERSION -f /tmp/agent-values.yaml \
              --set licensing.glooMeshLicenseKey=\$GLOO_MESH_LICENSE_KEY" >/dev/null

  wait_until "west-mini agent" 240 5 \
    on_remote "kubectl --context=kind-$WEST_NAME -n gloo-mesh wait --for=condition=Available deploy/gloo-mesh-agent --timeout=5s"

  # 5d: register west-mini with the mgmt plane (KubernetesCluster CR).
  if ! kubectl --context="kind-$EAST_NAME" -n gloo-mesh get kubernetescluster "$WEST_NAME" >/dev/null 2>&1; then
    log "  creating KubernetesCluster/$WEST_NAME on mgmt plane"
    cat <<YAML | kubectl --context="kind-$EAST_NAME" apply -f - >/dev/null
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: $WEST_NAME
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
YAML
  fi
  wait_until "both clusters ACCEPTED on mgmt plane" 120 5 \
    bash -c "kubectl --context=kind-$EAST_NAME -n gloo-mesh get kubernetescluster -o jsonpath='{range .items[*]}{.status.common.State.approval}{\"\\n\"}{end}' | grep -c ACCEPTED | grep -q '^2$'"
  ok "  both clusters ACCEPTED, agent connected via $EAST_LAN_IP:9900"
}

# ─── phase 6: force PEERING_AUTOMATIC_LOCAL_GATEWAY=false on both istiods ────
# An earlier version of this script set it to "true" thinking auto-distribution
# would help. It doesn't on kind-on-two-Macs:
#   - istiod-gloo publishes its local east-west GW's LB IP (172.x.255.100, a
#     Docker-bridge address — NOT routable on a second physical Mac).
#   - ConfigDistribution faithfully pushes that to the peer cluster as an
#     `istio-remote-peer-<cluster>` Gateway.
#   - istiod on the peer then has TWO Gateways targeting the same cluster: the
#     auto one (un-routable) and the manual LAN-IP one from phase 7. It gets
#     ambiguous and reports "Disconnected from <cluster> (address: <LAN-IP>)"
#     while the auto-Gateway self-loops via the local east-west GW (false ✓).
#
# Setting it to "false" cuts auto-distribution off at the publisher so the
# manual Gateways in phase 7 are the only peer Gateways anywhere. Idempotent:
# `kubectl set env` only triggers a rollout if the value actually changes.
phase_istiod_env() {
  log "── phase 6: set PEERING_AUTOMATIC_LOCAL_GATEWAY=false on both istiods ──"
  log "  (manual LAN-IP Gateways from phase 7 are the source of truth on 2-Mac kind)"
  for pair in "local:kind-$EAST_NAME" "remote:kind-$WEST_NAME"; do
    local side="${pair%%:*}" ctx="${pair##*:}"
    if [[ "$side" == "local" ]]; then
      kubectl --context=$ctx -n istio-system set env deploy/istiod-gloo PEERING_AUTOMATIC_LOCAL_GATEWAY=false >/dev/null
      kubectl --context=$ctx -n istio-system rollout status deploy/istiod-gloo --timeout=120s >/dev/null
    else
      on_remote "kubectl --context=$ctx -n istio-system set env deploy/istiod-gloo PEERING_AUTOMATIC_LOCAL_GATEWAY=false >/dev/null"
      on_remote "kubectl --context=$ctx -n istio-system rollout status deploy/istiod-gloo --timeout=120s" >/dev/null
    fi
    ok "  $ctx: PEERING_AUTOMATIC_LOCAL_GATEWAY=false applied"
  done
}

# ─── phase 7: manual peer Gateway CRs with explicit LAN IPs ──────────────────
# Why explicit-LAN-IP Gateways are required in kind-on-two-Macs:
#
# The auto-distributed `istio-remote-peer-<cluster>` Gateways that
# featureGates.ConfigDistribution generates use the east-west GW Service's
# `.status.loadBalancer.ingress[0].ip` — on kind that's a Docker-bridge IP
# (172.x.255.100) which is NOT routable from another physical Mac. On real
# cloud Kubernetes the LB EXTERNAL-IP is routable, so auto-peering works
# end-to-end there with no manual step. We override here with explicit-LAN-IP
# `istio-remote` Gateways pointing at the socat-published LAN ports.
#
# Critical detail: `gateway.istio.io/service-account: istio-eastwest` is
# required as an annotation. Without it the ztunnel client expects the SPIFFE
# SAN to derive from the Gateway's name (`manual-peer-X-istio-remote`), but
# the actual east-west GW pod runs as the `istio-eastwest` SA — mismatch
# breaks mTLS. With the annotation, ztunnel knows the real expected SAN.
#
# Also: after applying manual Gateways, we delete the auto self-peer Gateways
# (istiod creates these too) — keeping both causes ztunnel to select the
# unreachable Docker-bridge address sometimes. With only the manual ones
# left, routing is deterministic. Finally, istiod is restarted on both sides
# to flush its cached peer XDS connection (which sticks to the first-seen
# address even after the Gateway changes).
phase_peer_gateways() {
  log "── phase 7: apply manual LAN-routable peer Gateways ──"

  # 7a: east-laptop gets a peer Gateway pointing at west-mini's LAN IP.
  cat <<YAML | kubectl --context="kind-$EAST_NAME" apply -f - >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: manual-peer-$WEST_NAME
  namespace: istio-eastwest
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: cluster.local
  labels:
    topology.istio.io/cluster: $WEST_NAME
    topology.istio.io/network: $WEST_NAME
spec:
  gatewayClassName: istio-remote
  addresses:
    - { type: IPAddress, value: $WEST_LAN_IP }
  listeners:
    - { name: cross-network, port: 15008, protocol: HBONE, tls: { mode: Passthrough }, allowedRoutes: { namespaces: { from: Same } } }
    - { name: xds-tls,       port: 15012, protocol: TLS,   tls: { mode: Passthrough }, allowedRoutes: { namespaces: { from: Same } } }
YAML

  # 7b: west-mini gets a peer Gateway pointing at east-laptop's LAN IP.
  local west_yaml; west_yaml="$(mktemp -t super-quick-peer-east.XXXXXX.yaml)"
  cat >"$west_yaml" <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: manual-peer-$EAST_NAME
  namespace: istio-eastwest
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: cluster.local
  labels:
    topology.istio.io/cluster: $EAST_NAME
    topology.istio.io/network: $EAST_NAME
spec:
  gatewayClassName: istio-remote
  addresses:
    - { type: IPAddress, value: $EAST_LAN_IP }
  listeners:
    - { name: cross-network, port: 15008, protocol: HBONE, tls: { mode: Passthrough }, allowedRoutes: { namespaces: { from: Same } } }
    - { name: xds-tls,       port: 15012, protocol: TLS,   tls: { mode: Passthrough }, allowedRoutes: { namespaces: { from: Same } } }
YAML
  scp_q "$west_yaml" "$REMOTE:/tmp/peer-east.yaml" >/dev/null
  rm -f "$west_yaml"
  on_remote "kubectl --context=kind-$WEST_NAME apply -f /tmp/peer-east.yaml" >/dev/null

  # 7c: bounce istiod on both sides to flush cached peer XDS connection.
  log "  bouncing istiod (clears cached peer XDS connection)"
  kubectl --context="kind-$EAST_NAME" -n istio-system rollout restart deploy istiod-gloo >/dev/null
  on_remote "kubectl --context=kind-$WEST_NAME -n istio-system rollout restart deploy istiod-gloo" >/dev/null
  kubectl --context="kind-$EAST_NAME" -n istio-system rollout status deploy/istiod-gloo --timeout=120s >/dev/null
  on_remote "kubectl --context=kind-$WEST_NAME -n istio-system rollout status deploy/istiod-gloo --timeout=120s" >/dev/null

  # 7d: smoke-test LAN reachability between the two east-west GW socats — a
  # failure here pinpoints a Mac-side firewall / routing issue, not an istiod
  # bug. Critical because the symptom otherwise is the cryptic
  # "Disconnected from <cluster> (address: …)" from istioctl multicluster check.
  log "  smoke-testing LAN reachability on the east-west GW ports"
  local lan_ok=1
  for p in 15008 15012; do
    if ! nc -z -w 5 "$WEST_LAN_IP" "$p" 2>/dev/null; then
      warn "  $WEST_LAN_IP:$p NOT reachable from $EAST_NAME — firewall on $WEST_NAME's Mac?"
      lan_ok=0
    fi
    if ! on_remote "nc -z -w 5 $EAST_LAN_IP $p 2>/dev/null"; then
      warn "  $EAST_LAN_IP:$p NOT reachable from $WEST_NAME — firewall on $EAST_NAME's Mac?"
      lan_ok=0
    fi
  done
  if (( lan_ok == 0 )); then
    warn "  fix the firewall before retrying. macOS app firewall:"
    warn "    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off"
    warn "  (or add allow-rules for the socat containers — System Settings → Network → Firewall)"
  fi

  # 7e: delete auto-distributed peer Gateways AFTER the istiod rollout, and
  # keep deleting them during the wait. ConfigDistribution re-pushes them
  # whenever istiod re-syncs from the mgmt plane — if we delete pre-rollout
  # (as the script used to), they come back the moment istiod is back up.
  # The auto Gateways carry the Docker-bridge LB IP (172.x.255.100), which
  # routes back to istiod's own east-west GW on a single-host setup → false
  # "Connected" entries that mask the real manual-peer connectivity status.
  delete_auto_peers() {
    kubectl --context="kind-$EAST_NAME" -n istio-eastwest delete gateway \
      "istio-remote-peer-$EAST_NAME" "istio-remote-peer-$WEST_NAME" --ignore-not-found >/dev/null 2>&1 || true
    on_remote "kubectl --context=kind-$WEST_NAME -n istio-eastwest delete gateway \
      istio-remote-peer-$EAST_NAME istio-remote-peer-$WEST_NAME --ignore-not-found" >/dev/null 2>&1 || true
  }
  delete_auto_peers

  # 7f: verify peering via Solo's own check, re-deleting auto Gateways each
  # iteration so ConfigDistribution can't sneak them back.
  log "  waiting for multicluster peer ($EAST_NAME → $WEST_NAME via $WEST_LAN_IP)"
  local check_cmd="istioctl --context=kind-$EAST_NAME multicluster check 2>&1"
  local elapsed=0 connected="" final_state=""
  while (( elapsed < 240 )); do
    delete_auto_peers
    final_state="$(bash -c "$check_cmd")"
    if echo "$final_state" | grep -Eq "Connected to $WEST_NAME .*$WEST_LAN_IP|Peers Check: all clusters connected"; then
      # Belt-and-braces: the LAN-IP form is what we want, but if the auto-peer
      # delete just landed and the holistic "all clusters connected" line is
      # present, take it — it's the same signal one re-render later.
      connected=1; break
    fi
    sleep 5; elapsed=$(( elapsed + 5 ))
  done
  # Grace check: `istioctl multicluster check` itself takes several seconds,
  # and the connection sometimes lands right on the timeout boundary. Re-read
  # the state once more so we don't die on a check that just succeeded.
  if [[ -z "$connected" ]]; then
    final_state="$(bash -c "$check_cmd")"
    if echo "$final_state" | grep -Eq "Connected to $WEST_NAME .*$WEST_LAN_IP|Peers Check: all clusters connected"; then
      connected=1
    fi
  fi
  if [[ -z "$connected" ]]; then
    warn "  multicluster peers not connected after 240s — current state:"
    echo "$final_state" | sed 's/^/    /' >&2
    if (( lan_ok == 0 )); then
      die "  fix the LAN firewall (warnings above) and re-run"
    else
      die "  expected 'Connected to $WEST_NAME via $WEST_LAN_IP' in istioctl output"
    fi
  fi
  ok "  manual peer Gateways programmed, multicluster peer up ($EAST_LAN_IP ↔ $WEST_LAN_IP)"
}

# ─── phase 8: deploy bookinfo + Segment + Workspace + AccessPolicy ───────────
phase_demo_workloads() {
  log "── phase 8: deploy bookinfo + cross-cluster policy ──"

  # 8a: bookinfo (Istio sample app) on both clusters in `bookinfo` ns (ambient).
  local bookinfo_url; bookinfo_url="https://raw.githubusercontent.com/istio/istio/release-1.29/samples/bookinfo/platform/kube/bookinfo.yaml"
  for ctx_pair in "local:kind-$EAST_NAME" "remote:kind-$WEST_NAME"; do
    local side="${ctx_pair%%:*}" ctx="${ctx_pair##*:}"
    if [[ "$side" == "local" ]]; then
      kubectl --context=$ctx create ns bookinfo --dry-run=client -o yaml | kubectl --context=$ctx apply -f - >/dev/null
      kubectl --context=$ctx label ns bookinfo istio.io/dataplane-mode=ambient --overwrite >/dev/null
      kubectl --context=$ctx -n bookinfo apply -f "$bookinfo_url" >/dev/null
    else
      on_remote "kubectl --context=$ctx create ns bookinfo --dry-run=client -o yaml | kubectl --context=$ctx apply -f -" >/dev/null
      on_remote "kubectl --context=$ctx label ns bookinfo istio.io/dataplane-mode=ambient --overwrite" >/dev/null
      on_remote "kubectl --context=$ctx -n bookinfo apply -f $bookinfo_url" >/dev/null
    fi
  done

  # 8b: mark productpage Service as globally-scoped (Solo Ambient cross-cluster
  # discovery is driven by this label — synthetic VIP + cross-network endpoint).
  for ctx_pair in "local:kind-$EAST_NAME" "remote:kind-$WEST_NAME"; do
    local side="${ctx_pair%%:*}" ctx="${ctx_pair##*:}"
    if [[ "$side" == "local" ]]; then
      kubectl --context=$ctx -n bookinfo label svc productpage solo.io/service-scope=global --overwrite >/dev/null
    else
      on_remote "kubectl --context=$ctx -n bookinfo label svc productpage solo.io/service-scope=global --overwrite" >/dev/null
    fi
  done

  # 8c: Segment — vanity DNS aliases (`*.mesh.global` in addition to default
  # `*.mesh.internal`). NOT a routing primitive; pure DNS-alias layer.
  cat <<YAML | kubectl --context="kind-$EAST_NAME" apply -f - >/dev/null
apiVersion: admin.solo.io/v1alpha1
kind: Segment
metadata: { name: bookinfo-global, namespace: gloo-mesh }
spec:
  domain: mesh.global
  aliases:
    - pattern: "{service}.{namespace}.mesh.global"
YAML

  # 8d: Workspace + WorkspaceSettings — declare bookinfo as a workspace spanning
  # both clusters. AccessPolicy is scoped to a workspace's namespaces.
  cat <<YAML | kubectl --context="kind-$EAST_NAME" apply -f - >/dev/null
apiVersion: admin.gloo.solo.io/v2
kind: Workspace
metadata: { name: bookinfo, namespace: gloo-mesh }
spec:
  workloadClusters:
    - { name: $EAST_NAME, namespaces: [{ name: bookinfo }] }
    - { name: $WEST_NAME, namespaces: [{ name: bookinfo }] }
---
apiVersion: admin.gloo.solo.io/v2
kind: WorkspaceSettings
metadata: { name: bookinfo, namespace: bookinfo }
spec:
  options:
    serviceIsolation: { enabled: false }
YAML

  # 8e: AccessPolicy — one CR on the mgmt cluster, translated to
  # AuthorizationPolicy on EACH workload cluster. Demonstrates centralized
  # RBAC: "allow only SAs in bookinfo namespaces of these clusters to call
  # productpage on port 9080".
  cat <<YAML | kubectl --context="kind-$EAST_NAME" apply -f - >/dev/null
apiVersion: security.policy.gloo.solo.io/v2
kind: AccessPolicy
metadata: { name: productpage-allow-trusted-only, namespace: bookinfo }
spec:
  applyToDestinations:
    - port: { number: 9080 }
      selector:
        labels: { app: productpage }
  config:
    authn: { tlsMode: STRICT }
    authz:
      allowedClients:
        - serviceAccountSelector: { namespace: bookinfo, cluster: $EAST_NAME }
        - serviceAccountSelector: { namespace: bookinfo, cluster: $WEST_NAME }
YAML

  # 8f: wait for translation to land in both clusters.
  wait_until "translated AuthorizationPolicy on $EAST_NAME" 60 3 \
    bash -c "kubectl --context=kind-$EAST_NAME -n bookinfo get authorizationpolicy 2>&1 | grep -q accesspolicy-productpage"
  wait_until "translated AuthorizationPolicy on $WEST_NAME" 60 3 \
    on_remote "kubectl --context=kind-$WEST_NAME -n bookinfo get authorizationpolicy 2>&1 | grep -q accesspolicy-productpage"
  ok "  bookinfo deployed, AccessPolicy translated to AuthorizationPolicy on both clusters"
}

# ─── phase 9: verify cross-cluster failover end-to-end ───────────────────────
phase_verify() {
  log "── phase 9: verify cross-cluster failover ──"
  log "  scaling productpage-v1 on $EAST_NAME to 0"
  kubectl --context="kind-$EAST_NAME" -n bookinfo scale deploy productpage-v1 --replicas=0 >/dev/null
  kubectl --context="kind-$EAST_NAME" -n bookinfo wait --for=delete pod -l app=productpage --timeout=60s >/dev/null

  log "  three sequential curls via productpage.bookinfo.mesh.internal:9080"
  local passes=0
  for i in 1 2 3; do
    local code
    code=$(kubectl --context="kind-$EAST_NAME" -n bookinfo run "verify-$i" \
            --image=curlimages/curl --rm -i --restart=Never --quiet -- \
            sh -c 'curl -fsS -m 10 -o /dev/null -w "%{http_code}" http://productpage.bookinfo.mesh.internal:9080/productpage' 2>&1 \
          | tr -dc '0-9' | head -c 3)
    if [[ "$code" == "200" ]]; then
      ok "  attempt $i: HTTP 200 (cross-cluster failover to $WEST_NAME)"
      passes=$(( passes + 1 ))
    else
      warn "  attempt $i: HTTP $code (expected 200)"
    fi
  done

  log "  restoring productpage-v1 on $EAST_NAME"
  kubectl --context="kind-$EAST_NAME" -n bookinfo scale deploy productpage-v1 --replicas=1 >/dev/null

  (( passes == 3 )) || die "failover verification failed ($passes/3 returned 200)"
  ok "  ✓✓✓ failover green (3/3 HTTP 200 via west-mini)"
}

# ─── teardown ────────────────────────────────────────────────────────────────
phase_teardown() {
  log "── teardown both clusters ──"
  local quick_single="$REPO_ROOT/$QUICK_SINGLE_SCRIPT"
  local quick_single_subpath="${QUICK_SINGLE_SCRIPT%/scripts/*}"

  # Resolve REMOTE_SCRATCH (used for teardown as well as up).
  if [[ -z "$REMOTE_SCRATCH" ]]; then
    local rh; rh="$(on_remote 'printf %s "$HOME"')"
    [[ -n "$rh" ]] && REMOTE_SCRATCH="$rh/.super-quick"
  fi

  # Stop LAN tunnels first so we don't hold ports while clusters terminate.
  # Includes the inline mgmt-server 9900 tunnel that expose-ew-on-host.sh
  # doesn't know about, plus any legacy `relay-fwd-*` name from manual bootstraps.
  "$REPO_ROOT/$EXPOSE_SCRIPT" down "$EAST_NAME" 2>/dev/null || true
  docker ps -a --format '{{.Names}}' \
    | grep -E "^(ew-fwd-$EAST_NAME-9900|relay-fwd.*9900)\$" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
  on_remote "test -x $REMOTE_SCRATCH/scripts/expose-ew-on-host.sh \
             && $REMOTE_SCRATCH/scripts/expose-ew-on-host.sh down $WEST_NAME \
             || docker ps --format '{{.Names}}' | grep '^ew-fwd-$WEST_NAME-' | xargs -r docker rm -f" 2>/dev/null || true

  # Tear down local cluster via quick-single.
  ( cd "$REPO_ROOT" && "$quick_single" teardown "$EAST_NAME" ) || warn "local teardown reported error"

  # Tear down remote cluster — prefer the synced quick-single in scratch dir,
  # fall back to a direct `kind delete cluster` if scratch isn't present.
  on_remote "if [[ -x $REMOTE_SCRATCH/$quick_single_subpath/scripts/quick-single.sh ]]; then \
               cd $REMOTE_SCRATCH/$quick_single_subpath && bash scripts/quick-single.sh teardown $WEST_NAME; \
             else \
               kind delete cluster --name $WEST_NAME 2>/dev/null || true; \
             fi" || warn "remote teardown reported error"

  ok "both clusters torn down"
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
  if [[ "$ACTION" == "teardown" ]]; then phase_teardown; exit 0; fi

  log "─── super-quick: Solo Enterprise mgmt-plane on two Macs ───"
  log "  local  ($EAST_NAME)  =  this Mac"
  log "  remote ($WEST_NAME)  =  $REMOTE"
  log ""

  require_secrets
  require_prereqs   # also resolves REMOTE_HOME + REMOTE_SECRETS_FILE
  REMOTE_SCRATCH="$REMOTE_HOME/.super-quick"

  local t0=$SECONDS
  phase_build_clusters
  phase_uninstall_agw
  phase_expose_lan
  phase_install_mgmt
  phase_install_agent
  phase_istiod_env
  phase_peer_gateways
  if (( DEPLOY_BOOKINFO )); then
    phase_demo_workloads
    phase_verify
  else
    log "── skipping demo workloads (pass --deploy-bookinfo to include) ──"
  fi

  local elapsed=$(( SECONDS - t0 ))
  ok ""
  ok "─── done in ${elapsed}s ───"
  ok ""
  ok "Try it:"
  ok "  kubectl --context=kind-$EAST_NAME -n gloo-mesh get kubernetescluster"
  ok "  istioctl --context=kind-$EAST_NAME multicluster check"
  if (( DEPLOY_BOOKINFO )); then
    ok "  kubectl --context=kind-$EAST_NAME -n bookinfo get authorizationpolicy"
  else
    ok "  # Re-run with --deploy-bookinfo to add bookinfo + AccessPolicy + failover test"
  fi
  ok "  open http://localhost:8090 (port-forward UI:  kubectl --context=kind-$EAST_NAME -n gloo-mesh port-forward svc/gloo-mesh-ui 8090:8090)"
}

main "$@"

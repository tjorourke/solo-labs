#!/usr/bin/env bash
# lib.sh — shared helpers for istio-ambient-poc-eks.
#
# Two EKS clusters (eks-a, eks-b) in two peered VPCs, one VM, one Solo ambient
# mesh. The scripts run in order (00 → 09) and each one answers one POC
# question. AWS auth comes from LAB_AWS_PROFILE; nothing account-specific is
# written here.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOFU_DIR="$LAB_ROOT/tofu"
YAML_DIR="$LAB_ROOT/yaml"
STATE_DIR="$LAB_ROOT/.state"      # certs, VM tokens, notes (gitignored)
mkdir -p "$STATE_DIR"

# ── versions ──────────────────────────────────────────────────────────────────
# versions.env (repo matrix) uses ${VAR:-default}, so capture any runtime pin
# BEFORE sourcing it, then assign unconditionally: this lab runs ahead of the
# matrix on Solo Istio 1.30.4.
__pin_istio="${SOLO_ISTIO_VERSION:-}"
__pin_gwapi="${GATEWAY_API_VERSION:-}"
__versions_env="$(cd "$LAB_ROOT/.." 2>/dev/null && pwd)/versions.env"
[ -f "$__versions_env" ] && . "$__versions_env"
export SOLO_ISTIO_VERSION="${__pin_istio:-1.30.4-solo}"
export GATEWAY_API_VERSION="${__pin_gwapi:-v1.5.1}"
export GLOO_PLATFORM_VERSION="${GLOO_PLATFORM_VERSION:-2.13.3}"   # Gloo UI, pairs with Istio 1.30

export ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
export ISTIO_HELM_REPO="oci://us-docker.pkg.dev/soloio-img/istio-helm"
export ISTIO_TAG="$SOLO_ISTIO_VERSION"          # 1.30 line keeps the -solo suffix on image tags

# ── names ─────────────────────────────────────────────────────────────────────
export CLUSTER_A="${CLUSTER_A:-eks-a}"           # kube context alias == cluster == network name
export CLUSTER_B="${CLUSTER_B:-eks-b}"
export TRUST_DOMAIN_A="${CLUSTER_A}.local"       # per-cluster trust domains (Solo multicluster docs)
export TRUST_DOMAIN_B="${CLUSTER_B}.local"
export EW_NS="istio-eastwest"
export APP_NS="shop"
export VM_NS="vm-apps"
export GLOO_MESH_NS="gloo-mesh"

ka() { kubectl --context "$CLUSTER_A" "$@"; }
kb() { kubectl --context "$CLUSTER_B" "$@"; }

# ── output ────────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*" >&2; }
step() { echo ""; echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
show() { echo "  \$ $*"; "$@"; }      # print the command, then run it

# ── prerequisites ─────────────────────────────────────────────────────────────
require() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

load_secrets() {
  if [[ -n "${SECRETS_FILE:-}" ]]; then
    [[ -f "$SECRETS_FILE" ]] || die "SECRETS_FILE='$SECRETS_FILE' does not exist"
    set -a; . "$SECRETS_FILE"; set +a
  fi
}
require_license() {
  load_secrets
  [[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || die "SOLO_ISTIO_LICENSE_KEY not set (export it, or SECRETS_FILE=<file that exports it>)"
}
require_aws() {
  # Paid infrastructure: force an explicit profile choice. LAB_AWS_PROFILE wins
  # over anything a sourced secrets file exported into AWS_PROFILE.
  [[ -n "${LAB_AWS_PROFILE:-}" ]] || die "set LAB_AWS_PROFILE=<aws profile for this lab>"
  export AWS_PROFILE="$LAB_AWS_PROFILE"
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not working for profile '$AWS_PROFILE' (aws sso login --profile $AWS_PROFILE)"
  export AWS_REGION; AWS_REGION="$(tofu_out region)"
  export AWS_DEFAULT_REGION="$AWS_REGION"
}
require_contexts() {
  for c in "$CLUSTER_A" "$CLUSTER_B"; do
    kubectl config get-contexts -o name | grep -x "$c" >/dev/null || die "no kube context '$c' (run scripts/00-kubeconfig.sh)"
  done
}

# Solo distribution of istioctl, pinned to the mesh version. Uses whatever is on
# PATH if it already matches, otherwise downloads into .state/bin.
require_istioctl() {
  local want="$SOLO_ISTIO_VERSION" have=""
  if command -v istioctl >/dev/null 2>&1; then
    have="$(istioctl version --remote=false 2>/dev/null | awk '{print $NF}')"
  fi
  if [[ "$have" == "$want" ]]; then ISTIOCTL="$(command -v istioctl)"; export ISTIOCTL; return; fi
  ISTIOCTL="$STATE_DIR/bin/istioctl"
  if [[ ! -x "$ISTIOCTL" ]] || [[ "$("$ISTIOCTL" version --remote=false 2>/dev/null | awk '{print $NF}')" != "$want" ]]; then
    local os arch; os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
    [[ "$os" == "darwin" ]] && os="osx"
    case "$arch" in x86_64) arch=amd64;; aarch64) arch=arm64;; esac
    step "Downloading Solo istioctl $want ($os-$arch)"
    mkdir -p "$STATE_DIR/bin"
    curl -sSfL "https://storage.googleapis.com/soloio-istio-binaries/release/${want}/istio-${want}-${os}-${arch}.tar.gz" \
      | tar xz -C "$STATE_DIR" "istio-${want}/bin/istioctl"
    mv "$STATE_DIR/istio-${want}/bin/istioctl" "$ISTIOCTL"; rm -rf "$STATE_DIR/istio-${want}"
  fi
  export ISTIOCTL
  ok "istioctl $("$ISTIOCTL" version --remote=false 2>/dev/null) at $ISTIOCTL"
}

# ── tofu / AWS helpers ────────────────────────────────────────────────────────
tofu_out() { tofu -chdir="$TOFU_DIR" output -raw "$1" 2>/dev/null; }

# Run a shell snippet on the VM through SSM Session Manager (no SSH, no keys).
# ssm_run "<bash commands>"  → prints stdout/stderr, returns the remote exit code.
ssm_run() {
  local cmds="$1" id cid status
  id="$(tofu_out vm_instance_id)"
  local params; params="$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]]}))' "$cmds")"
  cid="$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
          --parameters "$params" --query Command.CommandId --output text)"
  for _ in $(seq 1 120); do
    status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in Pending|InProgress|Delayed) sleep 2;; *) break;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text | sed '/^$/d'
  [[ "$status" == "Success" ]]
}
wait_ssm_online() {
  local id; id="$(tofu_out vm_instance_id)"
  for _ in $(seq 1 60); do
    [[ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" == "Online" ]] && return 0
    sleep 5
  done
  die "VM $id never came online in SSM"
}

# wait_lb_host <ctx> <ns> <svc> → the LoadBalancer hostname once AWS assigns it
wait_lb_host() {
  local ctx="$1" ns="$2" svc="$3" host=""
  for _ in $(seq 1 90); do
    host="$(kubectl --context "$ctx" -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "$host" ]] && { echo "$host"; return 0; }
    sleep 5
  done
  return 1
}
# resolve_first_ip <hostname> → first A record (NLBs publish one per AZ)
resolve_first_ip() {
  local ip=""
  for _ in $(seq 1 60); do
    ip="$(dig +short "$1" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    sleep 5
  done
  return 1
}

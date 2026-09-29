#!/usr/bin/env bash
# The EKS GPU cluster behind the console's model-routing pages (Gateway decisions, Cost,
# My agents, Agentdesktop). Everything else in the suite runs on kind; this is the one
# piece that needs real GPUs, so it lives in your own AWS account.
#
#   ./demo-scripts/eks.sh check        what would be used: profile, account, region, cluster
#   ./demo-scripts/eks.sh render       the eksctl cluster definition `up` would create
#   ./demo-scripts/eks.sh up           build the cluster, the platform, both models, the flow
#   ./demo-scripts/eks.sh test         run the routing flow and the controls
#   ./demo-scripts/eks.sh endpoints    publish the gateway and UI on real hostnames (needs ZONE)
#   ./demo-scripts/eks.sh console-env  write the cluster's context into demo-console/console.env
#   ./demo-scripts/eks.sh context      print the cluster's kubectl context name
#   ./demo-scripts/eks.sh gpu up|down|status
#   ./demo-scripts/eks.sh teardown     remove the endpoints, the load balancers and the cluster
#
# It drives two labs that sit next to this suite and does nothing of its own:
#   ../agentgateway-inference-model-routing-eks   eks/cluster.yaml, gpu.sh, teardown
#   ../agentgateway-inference-task-routing-eks    the platform, the models and the routing flow
#
# Settings come from eks.env at the suite root (copy eks.env.example), keys from
# secrets.env. The GPUs are two g7e.2xlarge at about $11.70/hr together: run
# `eks.sh gpu down` at the end of every day. The weights stay on their volumes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$HERE/.." && pwd)"
LABS="$(cd "$LAB_ROOT/.." && pwd)"
PART1="$LABS/agentgateway-inference-model-routing-eks"
PART4="$LABS/agentgateway-inference-task-routing-eks"

die()  { echo "error: $*" >&2; exit 1; }
step() { echo; echo "############ $*"; }

[ -d "$PART1" ] && [ -d "$PART4" ] || die "expected the two EKS labs next to this suite:
  $PART1
  $PART4"

# Keys first, then the cluster settings, so eks.env wins over anything in secrets.env.
SECRETS_FILE="${SECRETS_FILE:-$LAB_ROOT/secrets.env}"
[ -f "$SECRETS_FILE" ] && { set -a; . "$SECRETS_FILE"; set +a; }
EKS_ENV="${EKS_ENV:-$LAB_ROOT/eks.env}"
[ -f "$EKS_ENV" ] && { set -a; . "$EKS_ENV"; set +a; }

export EKS_CLUSTER="${EKS_CLUSTER:-model-routing}"
export AWS_REGION="${AWS_REGION:-eu-west-2}"
export GPU_AZ="${GPU_AZ:-${AWS_REGION}a}"
export LAB_OWNER="${LAB_OWNER:-${USER:-lab-owner}}"

# Never build in whatever account the shell happens to be in. AWS_PROFILE must be named
# in eks.env, and the session must be in EXPECTED_AWS_ACCOUNT.
aws_guard() {
  [ -n "${AWS_PROFILE:-}" ] || die "set AWS_PROFILE in $EKS_ENV (copy eks.env.example)"
  [ -n "${EXPECTED_AWS_ACCOUNT:-}" ] || die "set EXPECTED_AWS_ACCOUNT in $EKS_ENV: the account this cluster belongs in"
  export AWS_PROFILE
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || die "no AWS session for profile $AWS_PROFILE. Run: aws sso login --profile $AWS_PROFILE"
  [ "$acct" = "$EXPECTED_AWS_ACCOUNT" ] \
    || die "profile $AWS_PROFILE is in account $acct, eks.env expects $EXPECTED_AWS_ACCOUNT. Nothing was changed."
}

# The kubectl context for the cluster. Part 4's scripts use the current context unless
# KUBE_CONTEXT names one, so it is always named here.
resolve_context() {
  # shellcheck source=/dev/null
  . "$PART1/scripts/lib-context.sh"
  unset KUBE_CONTEXT
  resolve_ctx
  export KUBE_CONTEXT="$CTX"
  echo "context: $KUBE_CONTEXT"
}

confirm() {
  [ "${YES:-}" = 1 ] && return
  read -r -p "$1 [y/N] " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || die "stopped, nothing changed"
}

summary() {
  cat <<EOF
  profile   ${AWS_PROFILE:-<unset>}
  account   ${EXPECTED_AWS_ACCOUNT:-<unset>}
  region    $AWS_REGION   (GPU zone $GPU_AZ)
  cluster   $EKS_CLUSTER   (Owner tag $LAB_OWNER)
  zone      ${ZONE:-<unset: no public endpoints>}
  secrets   $SECRETS_FILE $([ -f "$SECRETS_FILE" ] && echo "" || echo "(missing)")
EOF
}

case "${1:-}" in
  check)
    summary
    aws_guard
    echo "AWS session OK"
    if aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null 2>&1; then
      echo "cluster $EKS_CLUSTER exists"
      resolve_context
      "$PART1/scripts/gpu.sh" status
    else
      echo "cluster $EKS_CLUSTER does not exist yet: ./demo-scripts/eks.sh up"
    fi
    for v in AGENTGATEWAY_LICENSE_KEY ANTHROPIC_API_KEY; do
      [ -n "${!v:-}" ] && echo "$v set" || echo "$v MISSING (secrets.env)"
    done
    ;;

  up)
    summary
    aws_guard
    [ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ] || die "AGENTGATEWAY_LICENSE_KEY is not set (secrets.env)"
    [ -n "${ANTHROPIC_API_KEY:-}" ] || die "ANTHROPIC_API_KEY is not set (secrets.env)"
    confirm "Build EKS cluster $EKS_CLUSTER with two g7e.2xlarge (about \$11.70/hr while the GPUs are up)?"

    step "1/3  cluster (about 20 min)"
    if aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null 2>&1; then
      echo "cluster $EKS_CLUSTER already exists, skipping"
    else
      # Part 1's cluster definition, rendered with EKS_CLUSTER, AWS_REGION, GPU_AZ and
      # LAB_OWNER. `./demo-scripts/eks.sh render` shows it first.
      "$PART1/scripts/quick.sh" render | eksctl create cluster -f -
    fi
    resolve_context

    step "2/3  platform and models (the first run pulls about 76 GB of weights)"
    "$PART4/scripts/quick.sh" up

    step "3/3  console settings"
    "$0" console-env
    echo
    echo "Done. Prove it with:  ./demo-scripts/eks.sh test"
    echo "Publish hostnames for Cursor, Claude Desktop and the console's desktop pages:"
    echo "  set ZONE in eks.env, then ./demo-scripts/eks.sh endpoints"
    echo "Stop the GPU meter tonight:  ./demo-scripts/eks.sh gpu down"
    ;;

  render)
    "$PART1/scripts/quick.sh" render
    ;;

  context)
    # Just the context name on stdout, for other scripts.
    aws_guard; resolve_context >/dev/null
    echo "$KUBE_CONTEXT"
    ;;

  test)
    aws_guard; resolve_context
    "$PART4/scripts/quick.sh" test
    ;;

  endpoints)
    aws_guard; resolve_context
    [ -n "${ZONE:-}" ] || die "set ZONE in $EKS_ENV to a delegated Route53 zone you own"
    ZONE="$ZONE" "$PART4/scripts/platform/40-public-endpoints.sh" "${2:-}"
    ;;

  console-env)
    aws_guard; resolve_context
    f="$LAB_ROOT/demo-console/console.env"
    [ -f "$f" ] || cp "$LAB_ROOT/demo-console/console.env.example" "$f"
    # Replace the context line in place; hostnames are only written when ZONE is set.
    tmp="$(mktemp)"
    grep -vE '^(MODEL_ROUTING_CONTEXT|AGW_HOST|SOLO_UI_HOST)=' "$f" > "$tmp" || true
    echo "MODEL_ROUTING_CONTEXT=$KUBE_CONTEXT" >> "$tmp"
    if [ -n "${ZONE:-}" ]; then
      echo "AGW_HOST=agw.$ZONE" >> "$tmp"
      echo "SOLO_UI_HOST=soloui.$ZONE" >> "$tmp"
    else
      grep -E '^(AGW_HOST|SOLO_UI_HOST)=' "$f" >> "$tmp" || true
    fi
    mv "$tmp" "$f"
    echo "wrote $f"
    ;;

  gpu)
    aws_guard
    "$PART1/scripts/gpu.sh" "${2:-status}"
    ;;

  teardown)
    summary
    aws_guard
    confirm "Delete EKS cluster $EKS_CLUSTER, its load balancers and, if published, its DNS names?"
    if [ -n "${ZONE:-}" ] && [ -f "$PART4/tofu/terraform.tfstate" ]; then
      step "public endpoints"
      resolve_context
      ZONE="$ZONE" "$PART4/scripts/platform/40-public-endpoints.sh" destroy
    fi
    step "cluster"
    "$PART1/scripts/quick.sh" teardown
    ;;

  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac

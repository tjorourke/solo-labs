# Cluster selection, shared by every script in this lab. Source it, then use $CTX.
#
# Nothing here is tied to one cluster. By default it uses whatever kubectl context is
# current, which is what you want when you are already pointed at the right cluster.
# KUBE_CONTEXT names one explicitly. EKS_CLUSTER is the convenience for the cloud case,
# where the context name is an ARN nobody types by hand.
#
# WHY THIS IS NOT JUST STRING BUILDING. `aws eks update-kubeconfig` writes an ARN-named
# context, but eksctl writes `<user>@<cluster>.<region>.eksctl.io`, so a cluster you
# created with eksctl has no ARN context and building one gives you
# `context "arn:aws:eks:..." does not exist` on the first kubectl call. Look for a
# context that actually points at this cluster before falling back to writing one.

resolve_ctx() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then
    CTX="$KUBE_CONTEXT"
    return
  fi

  if [ -z "${EKS_CLUSTER:-}" ]; then
    CTX="$(command kubectl config current-context 2>/dev/null || true)"
    [ -n "$CTX" ] || {
      echo "error: no current kubectl context, and neither KUBE_CONTEXT nor EKS_CLUSTER is set." >&2
      exit 1
    }
    return
  fi

  local region account arn found cluster_entry
  region="${AWS_REGION:-eu-west-2}"
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  [ -n "$account" ] && [ "$account" != "None" ] \
    || { echo "error: no AWS identity. Check AWS_PROFILE, or run aws sso login." >&2; exit 1; }
  arn="arn:aws:eks:${region}:${account}:cluster/${EKS_CLUSTER}"

  # The ARN context, if update-kubeconfig has been run.
  if command kubectl config get-contexts -o name 2>/dev/null | grep -qxF "$arn"; then
    CTX="$arn"
    return
  fi

  # eksctl names the cluster entry <cluster>.<region>.eksctl.io and the context
  # <user>@<that>, so look for either shape before writing anything.
  for cluster_entry in "$arn" "${EKS_CLUSTER}.${region}.eksctl.io"; do
    found="$(command kubectl config view -o \
      "jsonpath={range .contexts[?(@.context.cluster=='${cluster_entry}')]}{.name}{'\n'}{end}" 2>/dev/null \
      | head -1)"
    if [ -n "$found" ]; then
      CTX="$found"
      return
    fi
  done

  # Nothing local knows about it, so write the ARN context and use that.
  echo "no kubectl context for $EKS_CLUSTER; writing one with aws eks update-kubeconfig" >&2
  aws eks update-kubeconfig --region "$region" --name "$EKS_CLUSTER" >/dev/null
  CTX="$arn"
}

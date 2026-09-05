#!/usr/bin/env bash
# install-ambient.sh — install Istio ambient on a GKE Autopilot cluster whose
# WorkloadAllowlists are already installed.
#
# This script asserts the allowlist prerequisites rather than doing them, because
# they involve an organisation policy change and a roughly 20 minute cluster
# update. Run generate-allowlists.sh, upload, authorise the paths on the org
# policy and the cluster, apply the synchroniser, then run this.
#
# Every Helm value below MUST match the ones generate-allowlists.sh rendered
# with. The allowlist pins the container image and lists env var names, so a
# mismatch fails admission while citing capabilities and hostPath, never the real
# cause.
set -uo pipefail

ISTIO_VER="${ISTIO_VER:-1.30.4}"
ISTIO_PROFILE="${ISTIO_PROFILE:-ambient}"
ISTIO_PLATFORM="${ISTIO_PLATFORM:-gke}"
ISTIO_CNI_BIN_DIR="${ISTIO_CNI_BIN_DIR:-/home/kubernetes/bin}"
ISTIO_APPARMOR_ANNOTATION="${ISTIO_APPARMOR_ANNOTATION:-false}"
AMBIENT_NAMESPACES="${AMBIENT_NAMESPACES:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_DIR="${YAML_DIR:-$HERE/../yaml}"

die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[33mwarn\033[0m %s\n' "$*" >&2; }
step(){ printf '\n\033[36m==>\033[0m %s\n' "$*"; }

command -v helm    >/dev/null || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"
CTX="$(kubectl config current-context)" || die "no current kubeconfig context"
kubectl version -o json >/dev/null 2>&1 || die "cannot reach the cluster"
printf 'context: %s\n' "$CTX"

step "Preflight: the allowlists must already be installed"
# Assert by NAME, not by count. Counting admits any two WorkloadAllowlists,
# including ones a different synchroniser installed, and the cniBinDir check
# below needs these two specifically. generate-allowlists.sh stamps these names
# on deliberately, replacing GKE's timestamped default.
MISSING=""
for want in "istio-cni-$ISTIO_VER" "istio-ztunnel-$ISTIO_VER"; do
  kubectl get workloadallowlist "$want" >/dev/null 2>&1 || MISSING="$MISSING $want"
done
if [[ -n "$MISSING" ]]; then
  printf 'installed:\n' >&2
  kubectl get workloadallowlists >&2 2>/dev/null || true
  die "missing WorkloadAllowlist(s):$MISSING
    Run ./generate-allowlists.sh, upload to the bucket, add the gs:// object
    paths (exact, not a directory prefix) to the
    container.managed.autopilotPrivilegedAdmission org policy and to the
    cluster's --autopilot-privileged-admission, then apply
    $YAML_DIR/02-allowlistsynchronizer.yaml and give it up to 10 minutes.
    If they never appear, read the synchroniser's own status:
      kubectl get allowlistsynchronizer istio-ambient -o yaml | sed -n '/^status:/,\$p'"
fi
ok "istio-cni-$ISTIO_VER and istio-ztunnel-$ISTIO_VER installed"
kubectl get workloadallowlists

# Assert the installed allowlist expects the same CNI directory we are about to
# install with. A mismatch here is the most confusing failure in this whole
# exercise: admission rejects the pod and cites capabilities and hostPath, never
# the directory.
WANT="$(kubectl get workloadallowlist -o jsonpath='{range .items[*]}{.matchingCriteria.volumes[?(@.name=="cni-bin-dir")].hostPath.path}{"\n"}{end}' 2>/dev/null | grep -v '^$' | head -1)"
if [[ -n "$WANT" && "$WANT" != "$ISTIO_CNI_BIN_DIR" ]]; then
  die "the allowlist expects cniBinDir=$WANT but this script installs $ISTIO_CNI_BIN_DIR.
    Regenerate with: ISTIO_CNI_BIN_DIR=$WANT ./generate-allowlists.sh"
fi
[[ -n "$WANT" ]] && ok "allowlist and install agree on cniBinDir=$WANT"

# Warn early rather than after a confusing rejection.
kubectl get workloadallowlist -o yaml 2>/dev/null | grep -q 'appArmorProfile' \
  || warn "no appArmorProfile in any installed allowlist. If istio-cni is refused,
     this is why: regenerate with ISTIO_APPARMOR_ANNOTATION=false."

step "The critical-pods ResourceQuota in istio-system"
kubectl create namespace istio-system >/dev/null 2>&1 || true
kubectl apply -f "$YAML_DIR/00-critical-pods-quota.yaml" >/dev/null \
  && ok "gcp-critical-pods quota present" \
  || warn "could not apply the critical-pods quota"

step "Istio $ISTIO_VER control plane (no allowlist needed)"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null 2>&1 || true

helm --kube-context "$CTX" upgrade -i istio-base istio/base \
  --version "$ISTIO_VER" -n istio-system --create-namespace >/dev/null \
  && ok "istio-base" || die "istio-base failed"

helm --kube-context "$CTX" upgrade -i istiod istio/istiod \
  --version "$ISTIO_VER" -n istio-system \
  --set profile="$ISTIO_PROFILE" --wait --timeout 10m >/dev/null \
  && ok "istiod (profile=$ISTIO_PROFILE)" || die "istiod failed"

step "Privileged data plane: istio-cni and ztunnel"
helm --kube-context "$CTX" upgrade -i istio-cni istio/cni \
  --version "$ISTIO_VER" -n istio-system \
  --set profile="$ISTIO_PROFILE" \
  --set global.platform="$ISTIO_PLATFORM" \
  --set cni.cniBinDir="$ISTIO_CNI_BIN_DIR" \
  --set cni.useAppArmorAnnotation="$ISTIO_APPARMOR_ANNOTATION" >/dev/null \
  && ok "istio-cni" || die "istio-cni failed"

helm --kube-context "$CTX" upgrade -i ztunnel istio/ztunnel \
  --version "$ISTIO_VER" -n istio-system \
  --set profile="$ISTIO_PROFILE" \
  --set global.platform="$ISTIO_PLATFORM" >/dev/null \
  && ok "ztunnel" || die "ztunnel failed"

step "Waiting for both DaemonSets"
for _ in $(seq 1 30); do
  READY=1
  for d in istio-cni-node ztunnel; do
    R="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.numberReady}' 2>/dev/null)"
    W="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
    [[ -n "$R" && "$R" == "$W" && "$R" -gt 0 ]] || READY=0
  done
  [[ "$READY" -eq 1 ]] && break
  sleep 20
done

for d in istio-cni-node ztunnel; do
  R="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.numberReady}' 2>/dev/null)"
  W="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
  if [[ "$R" == "$W" && "${R:-0}" -gt 0 ]]; then
    ok "$d $R/$W ready"
  else
    warn "$d is ${R:-0}/${W:-0}. Recent events:"
    kubectl -n istio-system describe ds "$d" 2>/dev/null | sed -n '/Events:/,$p' | tail -6 >&2
    # After you fix something the DaemonSet controller may not retry for
    # minutes, so its events go stale. Force a reconcile rather than waiting.
    warn "if you have just fixed the cause: kubectl -n istio-system rollout restart ds/$d"
    die "$d did not become ready"
  fi
done

if [[ -n "$AMBIENT_NAMESPACES" ]]; then
  step "Enrolling namespaces in ambient"
  # No pod restarts needed: istio-cni captures running pods in place and stamps
  # ambient.istio.io/redirection=enabled on each one.
  for ns in $AMBIENT_NAMESPACES; do
    kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null 2>&1 \
      && ok "$ns enrolled" || warn "could not label $ns"
  done
fi

step "Done"
echo "  prove it enforces something:  ./health-check.sh"

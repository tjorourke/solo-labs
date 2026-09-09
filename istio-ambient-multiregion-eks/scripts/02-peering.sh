#!/usr/bin/env bash
# 02-peering.sh — link the two regional meshes into one.
#
# Each cluster gets an east-west gateway (HBONE :15008 + XDS :15012) exposed on
# an internet-facing NLB — that is the cross-region fabric. Then each cluster
# learns the other's gateway (remote peering ref, using the peer's NLB DNS), and
# istiod discovers the peer's services and workloads over the mTLS xDS
# connection to that gateway.
#
# There are deliberately NO remote secrets here. In the Solo distribution the two
# control planes exchange federated service and workload information over xDS on
# :15012, so neither region's istiod ever holds a kubeconfig for the other or
# reaches its Kubernetes API. Community Istio is the one that needs remote
# secrets and API access into every cluster. This script asserts the absence.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_license; require_aws; require_istioctl

CTX1="$(ctx_of "$NAME1" "$REGION1")"; CTX2="$(ctx_of "$NAME2" "$REGION2")"
[[ -n "$CTX1" && -n "$CTX2" ]] || die "missing kube contexts"

ew_install() {
  local ctx="$1" name="$2"
  step "[$name] east-west gateway on an internet-facing NLB"
  kubectl --context "$ctx" create namespace istio-eastwest --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f - >/dev/null
  helm --kube-context "$ctx" upgrade -i "peering-${name}" "$ISTIO_HELM_REPO/peering" \
    -n istio-eastwest --version "$ISTIO_HELM_VERSION" --wait --timeout 5m -f - >/dev/null <<EOF
eastwest:
  create: true
  cluster: ${name}
  network: ${name}
  service:
    metadata:
      annotations:
        # in-tree controller (no AWS LB Controller on a stock eksctl cluster):
        # this single annotation makes the LB an internet-facing NLB
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    # Annotations only, no spec.ports. The Service is created and owned by
    # istiod's east-west controller (ownerRef Gateway/istio-eastwest,
    # gateway.istio.io/managed=istio.io-eastwest-controller), so let the
    # controller publish the ports. This matches istio-ambient-poc-eks, the
    # two-EKS setup that is validated on this version.
    #
    # Note: this is not the fix for the :15012 problem described in the README.
    # The controller publishes exactly the same three ports the override used to
    # hard-code (15021, 15008, tls-xds 15012 -> 15012), and the gateway pod still
    # binds no 15012 listener either way, so that target group still fails its
    # health checks. Removing the override just stops this lab second-guessing
    # the controller.
remote:
  create: false
EOF
  ok "[$name] east-west gateway installed"
}

lb_host() { # lb_host <ctx> — wait for the eastwest LB hostname
  local ctx="$1" host=""
  for _ in $(seq 1 60); do
    host="$(kubectl --context "$ctx" -n istio-eastwest get svc istio-eastwest \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    [[ -n "$host" ]] && { echo "$host"; return 0; }
    sleep 5
  done
  return 1
}

ew_install "$CTX1" "$NAME1"
ew_install "$CTX2" "$NAME2"

step "Waiting for NLB hostnames"
HOST1="$(lb_host "$CTX1")" || die "no LB hostname on $NAME1"
HOST2="$(lb_host "$CTX2")" || die "no LB hostname on $NAME2"
ok "$NAME1 -> $HOST1"
ok "$NAME2 -> $HOST2"

remote_ref() { # remote_ref <ctx> <own-name> <peer-name> <peer-host>
  local ctx="$1" name="$2" peer="$3" host="$4"
  step "[$name] remote peer reference -> $peer"
  helm --kube-context "$ctx" upgrade -i "remote-${name}" "$ISTIO_HELM_REPO/peering" \
    -n istio-eastwest --version "$ISTIO_HELM_VERSION" -f - >/dev/null <<EOF
eastwest:
  create: false
remote:
  create: true
  items:
    - cluster: ${peer}
      network: ${peer}
      trustDomain: cluster.local
      address: ${host}
      addressType: Hostname   # NLBs give DNS names, not IPs
      hbonePort: 15008
      xdsPort: 15012
EOF
  ok "[$name] knows $peer via $host"
}
remote_ref "$CTX1" "$NAME1" "$NAME2" "$HOST2"
remote_ref "$CTX2" "$NAME2" "$NAME1" "$HOST1"

# No remote secrets. This is the whole point of peering: discovery rides the
# istiod-to-istiod xDS connection, so neither cluster is given a kubeconfig or
# any access to the other's Kubernetes API. Assert it rather than assume it —
# istiod also has DISABLE_LEGACY_MULTICLUSTER=true, so a stray secret from an
# older run of this lab would be ignored, and a silently-ignored secret is
# exactly the thing that made this lab's "no API access" claim untrue before.
step "Assert no remote secrets exist (peering must not need Kube API access)"
for pair in "$CTX1:$NAME1" "$CTX2:$NAME2"; do
  IFS=: read -r ctx name <<<"$pair"
  found="$(kubectl --context "$ctx" -n istio-system get secrets \
    -l 'istio/multiCluster=true' -o name 2>/dev/null || true)"
  # older/hand-built secrets are labelled networking.istio.io/remote instead
  found+="$(kubectl --context "$ctx" -n istio-system get secrets \
    -o name 2>/dev/null | grep '^secret/istio-remote-secret-' || true)"
  if [[ -n "$found" ]]; then
    echo "$found" >&2
    die "[$name] a remote secret is present — this lab peers over xDS and must not use remote secrets. Delete it and re-run."
  fi
  ok "[$name] no remote secret"
done

# `remote-clusters` is the LEGACY remote-secret inventory: with peering it lists
# only the local cluster, because the peer is known through the xDS peering
# subsystem rather than a kubeconfig Secret. Printed for the record; the real
# assertion is `multicluster check` below.
step "Legacy remote-secret inventory (expected: local cluster only)"
"$ISTIOCTL" --context "$CTX1" remote-clusters 2>/dev/null || true
"$ISTIOCTL" --context "$CTX2" remote-clusters 2>/dev/null || true

# Poll, do not check once. The remote peer refs above point at NLB DNS names, and
# an AWS NLB is routinely a few minutes behind the Gateway going Programmed.
# Checking immediately reports a disconnected mesh for a setup that is merely
# still coming up.
#
# Assert on the Peers Check LINE, not on the exit code. `multicluster check`
# exits non-zero for warnings as well as failures, and this install always
# carries two harmless ones (License Check is not evaluated on a plain-Helm
# istiod, and the env-var check is advisory), so an exit-code loop here can never
# succeed even when both clusters are fully peered. Both directions must report
# connected: a one-way check passes while return traffic has nowhere to go.
step "Check peering converges (NLB DNS lags the gateway becoming ready)"
__mc_out="$(mktemp)"; trap 'rm -f "$__mc_out"' EXIT
__end=$(( $(date +%s) + 900 ))
__peers=0
while [[ $(date +%s) -lt $__end ]]; do
  "$ISTIOCTL" multicluster check --contexts "$CTX1,$CTX2" >"$__mc_out" 2>&1 || true
  # Match the text, not the tick: the emoji is cosmetic and could change, while
  # a failing check prints "Peers Check: found disconnected cluster(s)" instead.
  __peers="$(grep -cE 'Peers Check: all clusters connected' "$__mc_out" || true)"
  [[ "$__peers" -ge 2 ]] && break
  echo "  not converged yet ($__peers/2 clusters report peers connected), retrying in 20s"
  sleep 20
done
cat "$__mc_out"
[[ "$__peers" -ge 2 ]] \
  || die "peering did not converge within 15m — only $__peers/2 clusters report 'Peers Check: all clusters connected'"
ok "peered over xDS, no remote secrets, no cross-cluster Kube API access"

#!/usr/bin/env bash
# 02-peering.sh — link the two regional meshes into one.
#
# Each cluster gets an east-west gateway (HBONE :15008 + XDS :15012) exposed on
# an internet-facing NLB — that is the cross-region fabric. Then each cluster
# learns the other's gateway (remote peering ref, using the peer's NLB DNS) and
# gets a remote secret so istiod can discover the peer's endpoints.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
require_license; require_aws

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
    spec:
      type: LoadBalancer
      ports:
        - name: tls-hbone
          port: 15008
          protocol: TCP
        - name: tls-xds
          port: 15012
          protocol: TCP
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

step "Cross-applying remote secrets (control-plane discovery)"
istioctl create-remote-secret --context "$CTX1" --name "$NAME1" | kubectl --context "$CTX2" apply -f - >/dev/null
istioctl create-remote-secret --context "$CTX2" --name "$NAME2" | kubectl --context "$CTX1" apply -f - >/dev/null
ok "remote secrets applied both ways"

echo
step "Peering status"
istioctl --context "$CTX1" remote-clusters 2>/dev/null || true
istioctl --context "$CTX2" remote-clusters 2>/dev/null || true
ok "peering configured — allow ~1-2 min for the gateways to sync"

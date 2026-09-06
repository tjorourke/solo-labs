#!/usr/bin/env bash
# 06-vm.sh — scenario 4: enrol the EC2 VM into the mesh. istioctl mints the
# workload identity + a bootstrap token, ztunnel runs on the VM as a container,
# mesh pods reach the VM app by a normal Kubernetes hostname, and the VM app
# reaches mesh services through ztunnel's SOCKS5 port with its own identity.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_aws; require_contexts; require_istioctl
A="$CLUSTER_A"
VM_IP="$(tofu_out vm_private_ip)"; VM_HOST="mesh-vm"
TOKENS="$STATE_DIR/vm-tokens"; mkdir -p "$TOKENS"

step "[$A] namespace for VM workloads (ambient-enrolled like any other)"
kubectl --context "$A" create namespace "$VM_NS" --dry-run=client -o yaml | kubectl --context "$A" apply -f - >/dev/null
kubectl --context "$A" label ns "$VM_NS" istio.io/dataplane-mode=ambient --overwrite >/dev/null

step "[$A] istioctl vm add-workload: ServiceAccount + WorkloadEntry + tokens for vm-app on $VM_IP"
OUT="$("$ISTIOCTL" --context "$A" vm add-workload vm-app \
  --external --address "$VM_IP" --namespace "$VM_NS" \
  --ports http:80:8080 --hostname "$VM_HOST" --output-dir "$TOKENS" --bootstrap 2>&1)"
echo "$OUT" | grep -v 'BOOTSTRAP_TOKEN=' | sed 's/^/  /'
# `|| true` then an explicit check: a missing token should report what went wrong,
# not die inside a command substitution with no message.
BOOTSTRAP="$(echo "$OUT" | grep -o 'BOOTSTRAP_TOKEN=[^ ]*' | head -1 | cut -d= -f2- || true)"
[[ -n "$BOOTSTRAP" ]] || die "no BOOTSTRAP_TOKEN in the onboarding output; check the istiod logs"
[[ -n "$BOOTSTRAP" ]] || die "no bootstrap token in istioctl output"
echo "$BOOTSTRAP" > "$TOKENS/bootstrap.token"
[[ -f "$TOKENS/vm-app.token" ]] || die "vm-app.token not written"
ok "bootstrap token + vm-app.token in $TOKENS"
kubectl --context "$A" -n "$VM_NS" get workloadentry,serviceentry,sa 2>/dev/null | sed 's/^/  /'

step "[VM] place the workload token, start ztunnel with the bootstrap token (via SSM)"
wait_ssm_online
ssm_run "set -e
mkdir -p /etc/ztunnel/tokens/${VM_NS}/vm-app
printf '%s' '$(tr -d '\n' < "$TOKENS/vm-app.token")' > /etc/ztunnel/tokens/${VM_NS}/vm-app/token   # no trailing newline: it becomes a header value
docker rm -f ztunnel >/dev/null 2>&1 || true
docker run -d --name ztunnel --network host --restart unless-stopped \
  -e BOOTSTRAP_TOKEN='${BOOTSTRAP}' \
  -v /etc/ztunnel:/etc/ztunnel:ro \
  ${ISTIO_REGISTRY}/ztunnel:${ISTIO_TAG}
sleep 8
docker ps --format '{{.Names}} {{.Status}} {{.Image}}'
docker logs ztunnel 2>&1 | grep -iE 'error|connected|xds|listener|socks' | tail -6"

step "[$A] ztunnel in the cluster now lists the VM workload"
sleep 5
"$ISTIOCTL" --context "$A" ztunnel-config workloads --workload-namespace "$VM_NS"

step "[$A frontend] -> vm-app.vm-apps.svc.cluster.local (mesh pod to VM, over HBONE)"
for _ in 1 2 3; do
  kubectl --context "$A" -n "$APP_NS" exec deploy/frontend -- curl -s -m8 http://vm-app.vm-apps.svc.cluster.local/ ; echo
done

step "[VM] vm-app -> catalog in the cluster, through ztunnel's SOCKS5 port, as identity vm-app.vm-apps"
ssm_run "ALL_PROXY=socks5h://vm-app.${VM_NS}:pass@127.0.0.1:15080 curl -s -o /dev/null -w 'vm-app -> catalog: %{http_code} (not in the policy yet)\n' -m8 http://catalog.shop.svc.cluster.local:8080/ || true"
echo "  [$A ztunnel] identity seen by catalog's ztunnel:"
sleep 2
kubectl --context "$A" -n istio-system logs ds/ztunnel --since=30s 2>/dev/null \
  | grep 'dst.service="catalog.shop' | grep -o 'src.identity="[^"]*vm-app[^"]*"' | sort -u | sed 's/^/   /' || true

step "[$A] allow vm-app in the catalog policy (it is a principal like any pod)"
show kubectl --context "$A" apply -f "$YAML_DIR/security/authz-catalog-vm.yaml"
sleep 3
ssm_run "ALL_PROXY=socks5h://vm-app.${VM_NS}:pass@127.0.0.1:15080 curl -s -o /dev/null -w 'vm-app -> catalog: %{http_code}\n' -m8 http://catalog.shop.svc.cluster.local:8080/"

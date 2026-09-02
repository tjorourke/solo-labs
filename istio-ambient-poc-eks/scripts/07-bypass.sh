#!/usr/bin/env bash
# 07-bypass.sh — scenario 5: an app that does not go through the pod's Linux
# network path. Show what ambient cannot see (a hostNetwork client), then the
# pattern that still gives such an app a real identity: talk to ztunnel
# explicitly over SOCKS5, one identity per workload, on the same VM.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_aws; require_contexts; require_istioctl
A="$CLUSTER_A"
VM_IP="$(tofu_out vm_private_ip)"
TOKENS="$STATE_DIR/vm-tokens"

step "[$A] a hostNetwork client in the ambient namespace: is it in the mesh?"
kubectl --context "$A" apply -f "$YAML_DIR/security/hostnet.yaml" >/dev/null
kubectl --context "$A" -n "$APP_NS" wait pod/hostnet --for=condition=Ready --timeout=120s >/dev/null
"$ISTIOCTL" --context "$A" ztunnel-config workloads --workload-namespace "$APP_NS" | grep -E 'NAME|hostnet' || echo "  (hostnet is not listed: ztunnel has no netns to capture)"
echo -n "  hostnet -> catalog (STRICT + policy in place): "
kubectl --context "$A" -n "$APP_NS" exec hostnet -- curl -s -o /dev/null -w '%{http_code}\n' -m5 http://catalog.shop.svc.cluster.local:8080/ || echo "refused (plaintext from the node IP, no identity)"

step "[$A] second identity on the SAME VM: vm-batch (no --bootstrap, the VM's ztunnel already runs)"
"$ISTIOCTL" --context "$A" vm add-workload vm-batch --external --address "$VM_IP" --namespace "$VM_NS" --hostname mesh-vm \
  --ports http:80:9090 --output-dir "$TOKENS" 2>&1 | grep -v BOOTSTRAP_TOKEN | sed 's/^/  /'
ssm_run "mkdir -p /etc/ztunnel/tokens/${VM_NS}/vm-batch
printf '%s' '$(tr -d '\n' < "$TOKENS/vm-batch.token")' > /etc/ztunnel/tokens/${VM_NS}/vm-batch/token   # no trailing newline: it becomes a header value
ls -R /etc/ztunnel/tokens"
sleep 5

step "[VM] same host, same ztunnel, two identities: vm-app is allowed, vm-batch is not"
ssm_run "ALL_PROXY=socks5h://vm-app.${VM_NS}:pass@127.0.0.1:15080   curl -s -o /dev/null -w 'vm-app   -> catalog: %{http_code}\n' -m8 http://catalog.shop.svc.cluster.local:8080/ || true
ALL_PROXY=socks5h://vm-batch.${VM_NS}:pass@127.0.0.1:15080 curl -s -o /dev/null -w 'vm-batch -> catalog: %{http_code}\n' -m8 http://catalog.shop.svc.cluster.local:8080/ || echo 'vm-batch -> catalog: refused'"
sleep 2
echo "  [$A ztunnel] decisions for the two VM identities:"
kubectl --context "$A" -n istio-system logs ds/ztunnel --since=30s 2>/dev/null \
  | grep -E 'vm-app|vm-batch' | grep -oE 'src.identity="[^"]*"( .*error="[^"]*")?' | sort | uniq -c | sed 's/^/   /' || true

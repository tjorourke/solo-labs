#!/usr/bin/env bash
# teardown.sh — delete the LoadBalancer Services first (they are AWS NLBs the
# VPC cannot be destroyed under), then tofu destroy everything.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_aws
for c in "$CLUSTER_A" "$CLUSTER_B"; do
  kubectl config get-contexts -o name | grep -x "$c" >/dev/null || continue
  step "[$c] removing LoadBalancer services"
  kubectl --context "$c" delete gateway --all -n "$EW_NS" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  helm --kube-context "$c" uninstall istio-eastwest -n "$EW_NS" >/dev/null 2>&1 || true
  kubectl --context "$c" get svc -A -o json 2>/dev/null \
    | python3 -c "import json,sys; [print(i['metadata']['namespace'], i['metadata']['name']) for i in json.load(sys.stdin)['items'] if i['spec'].get('type')=='LoadBalancer']" \
    | while read -r ns name; do kubectl --context "$c" -n "$ns" delete svc "$name" --wait=false >/dev/null 2>&1 || true; log "deleted svc $ns/$name"; done
done
sleep 60
step "tofu destroy"
tofu -chdir="$TOFU_DIR" destroy -auto-approve
for c in "$CLUSTER_A" "$CLUSTER_B"; do kubectl config delete-context "$c" >/dev/null 2>&1 || true; done
ok "gone"

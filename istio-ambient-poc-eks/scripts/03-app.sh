#!/usr/bin/env bash
# 03-app.sh — the sample app in BOTH clusters (frontend -> catalog), catalog
# published as a global service.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_aws; require_contexts

for c in "$CLUSTER_A" "$CLUSTER_B"; do
  step "[$c] shop namespace: frontend + catalog"
  sed "s/CLUSTER/$c/g" "$YAML_DIR/app/shop.yaml" | kubectl --context "$c" apply -f - >/dev/null
  kubectl --context "$c" -n "$APP_NS" rollout status deploy/catalog deploy/frontend --timeout=180s >/dev/null
  ok "[$c] running"
done

sleep 6
for c in "$CLUSTER_A" "$CLUSTER_B"; do
  echo "[$c frontend]"; kubectl --context "$c" -n "$APP_NS" logs deploy/frontend --tail=3 | sed 's/^/   /'
done

#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
# Fetch the pinned runtime before creating six pods. A cold kubelet pull left
# every runtime waiting for the same image until the rollout budget expired.
# Use the host cache and explicit kind import, as the identity/mesh phases do.
image="ghcr.io/kagent-dev/kagent/app:$KAGENT_RUNTIME_VERSION"
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
platform="linux/$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
docker image save --platform "$platform" -o "$archive" "$image"
kind load image-archive "$archive" --name trustusbank-lab
rm -f "$archive"
trap - EXIT
apply "$LAB/yaml/agents.yaml"
# Restore the verified bearer after the generated JWT policy so the runtime
# can exchange it. The extra Require rule checks the human on controller calls.
apply "$LAB/yaml/agent-identity.yaml"
apply "$LAB/yaml/access.yaml"
apply "$LAB/yaml/refunds-discovery.yaml"
for name in customer-agent fraud-agent refunds-agent customer-service-assistant payments-assistant payments-manager; do
  for attempt in {1..60}; do
    if k -n bank get "agent/$name" -o json | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(d["metadata"]["generation"] != d.get("status",{}).get("observedGeneration"))'; then break; fi
    sleep 2
  done
  k -n bank rollout status "deployment/$name" --timeout=8m
  k -n bank wait --for=condition=Ready "agent/$name" --timeout=8m
done
apply "$LAB/yaml/payments-lockdown.yaml"
apply "$LAB/yaml/audit.yaml"
# Remove the obsolete implementation only after the replacements are Ready.
k -n bank delete agent orchestrator ledger-agent payments-approval --ignore-not-found
k -n bank delete accesspolicy payments-approval-managers --ignore-not-found
k -n bank delete enterpriseagentgatewaypolicy payments-approval-human-identity refund-approval-status-identity --ignore-not-found
k -n bank delete httproute refund-approval-status refund-approval-edge --ignore-not-found
k -n bank delete service refund-approval-status --ignore-not-found
k -n bank delete gateway bank-approval-status --ignore-not-found
k -n bank delete remotemcpserver bank-delegation --ignore-not-found
k -n bank delete service bank-delegation --ignore-not-found
k -n bank delete authorizationpolicy ledger-workload assistant-entry kill-ledger-instance payments-gateway-only --ignore-not-found
k -n bank delete enterpriseagentgatewaypolicy payments-chain-authz --ignore-not-found
k -n bank delete secret bank-model --ignore-not-found
k -n kagent delete secret bank-model --ignore-not-found
k -n bank delete modelconfig bank-ui-model --ignore-not-found
printf 'Six declarative agents Ready; native manager approval configured.\n'

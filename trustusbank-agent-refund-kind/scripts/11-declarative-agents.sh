#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
apply "$LAB/yaml/agents.yaml"
# Restore the verified bearer after the generated JWT policy so the runtime
# can exchange it. The extra Require rule checks the human on controller calls.
apply "$LAB/yaml/agent-identity.yaml"
apply "$LAB/yaml/access.yaml"
apply "$LAB/yaml/refunds-discovery.yaml"
for name in customer-agent fraud-agent refunds-agent customer-service-assistant payments-assistant; do
  for attempt in {1..60}; do
    if k -n bank get "agent/$name" -o json | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(d["metadata"]["generation"] != d.get("status",{}).get("observedGeneration"))'; then break; fi
    sleep 2
  done
  k -n bank rollout status "deployment/$name" --timeout=240s
  k -n bank wait --for=condition=Ready "agent/$name" --timeout=240s
done
apply "$LAB/yaml/payments-lockdown.yaml"
apply "$LAB/yaml/audit.yaml"
# Remove the obsolete implementation only after the replacements are Ready.
k -n bank delete agent orchestrator ledger-agent --ignore-not-found
k -n bank delete remotemcpserver bank-delegation --ignore-not-found
k -n bank delete service bank-delegation --ignore-not-found
k -n bank delete authorizationpolicy ledger-workload assistant-entry kill-ledger-instance payments-gateway-only --ignore-not-found
k -n bank delete enterpriseagentgatewaypolicy payments-chain-authz --ignore-not-found
k -n bank delete secret bank-model --ignore-not-found
k -n kagent delete secret bank-model --ignore-not-found
k -n bank delete modelconfig bank-ui-model --ignore-not-found
printf 'Five declarative agents Ready; legacy runtime removed.\n'

#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
# Resolve the remote port from the installed Service, never from chart defaults.
case "${1:-kagent}" in
  kagent) ns=kagent; service=kagent-ui; port_name=ui; local_port=18380 ;;
  management) ns=agentgateway-system; service=solo-enterprise-ui; port_name=http; local_port=18390 ;;
  *) printf 'Usage: ui-forward.sh {kagent|management}\n' >&2; exit 2 ;;
esac
port=$(k -n "$ns" get svc "$service" -o "jsonpath={.spec.ports[?(@.name=='$port_name')].port}")
[[ -n "$port" ]] || { printf 'UI Service port missing\n' >&2; exit 1; }
k -n "$ns" port-forward "svc/$service" "$local_port:$port"

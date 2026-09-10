#!/usr/bin/env bash
# fix-cluster-dns.sh — make the cluster resolve its OWN ingress names locally.
#
# The suite puts every console and MCP endpoint on <name>.<LB-IP>.sslip.io. sslip.io
# answers by decoding the IP out of the name, so the answer is a private address, and
# plenty of home-router and ISP resolvers refuse to return a private address for a
# public name (DNS rebinding protection). When that happens the failure is horrible:
# `arctl` cannot reach the registry, and in-cluster callers get
# "Failed to create MCP session", because CoreDNS forwards to the same broken resolver.
#
# sslip.io encodes the IP in the name, so the cluster never needed to ask anyone. This
# gives CoreDNS a hosts block for the names this suite uses. Idempotent.
set -euo pipefail
K="kubectl --context ${CTX:-kind-mesh1}"
LB="${LB:-$($K -n agentgateway-system get gateway ar-ingress -o jsonpath='{.status.addresses[0].value}')}"
[ -n "$LB" ] || { echo "✗ could not find the ar-ingress address"; exit 1; }

CF="$($K -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
if printf '%s' "$CF" | grep -q "sslip.io"; then
  echo "CoreDNS already answers the sslip.io names locally"
else
  NEW="$(printf '%s' "$CF" | python3 -c "
import sys
lb='$LB'
names=' '.join('%s.%s.sslip.io'%(n,lb) for n in
               ('agentregistry','kagent','keycloak','github-mcp','petstore','calc'))
cf=sys.stdin.read()
block='    # answer this cluster\'s own ingress names locally: sslip.io encodes the IP in\n'
block+='    # the name, and public resolvers with rebinding protection refuse to return\n'
block+='    # a private address, which silently breaks every in-cluster caller.\n'
block+='    hosts {\n       %s %s\n       fallthrough\n    }\n' % (lb, names)
print(cf.replace('    prometheus :9153\n', block+'    prometheus :9153\n'), end='')
")"
  $K -n kube-system patch configmap coredns --type=merge \
    -p "$(python3 -c "import json,sys;print(json.dumps({'data':{'Corefile':sys.argv[1]}}))" "$NEW")" >/dev/null
  $K -n kube-system rollout restart deploy/coredns >/dev/null
  $K -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
  echo "✓ CoreDNS now answers *.${LB}.sslip.io locally"
fi

echo
echo "== check from inside the cluster =="
# resolve from inside the cluster, using whatever pod is already there
POD="$($K -n kagent get pods -l app.kubernetes.io/name=prtriage -o name 2>/dev/null | head -1)"
if [ -n "$POD" ]; then
  $K -n kagent exec "${POD#*/}" -- python3 -c "
import socket,sys
h=sys.argv[1]
try: print('  %s -> %s' % (h, socket.gethostbyname(h)))
except Exception as e: print('  %s FAILS: %s' % (h, e))
" "github-mcp.${LB}.sslip.io" 2>/dev/null || echo "  (agent pod could not run the check; the CoreDNS change is applied regardless)"
else
  echo "  (the agent is not deployed yet, so nothing to check from; CoreDNS is configured)"
fi

echo
echo "NOTE: this fixes the CLUSTER only. Your laptop still needs a resolver that will"
echo "return private addresses. Tailscale: admin console -> DNS -> Split DNS -> add"
echo "'sslip.io' with nameserver 1.1.1.1. Or add 1.1.1.1 to the Mac's DNS servers."

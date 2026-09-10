#!/usr/bin/env bash
# setup.sh — stand up Part 8 on mesh1, on top of the Part 4 platform.
#
# Needs: the Part 4 standup (demo-scripts/agentregistry/setup-mesh1.sh) already
# done, and GITHUB_PAT (or GITHUB_PORTLAB_TOKEN) in the environment. The PAT only
# ever needs READ access: this demo reads public pull requests, and the whole
# point of §9 is that write tools are denied at the gateway rather than withheld
# from the token.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context kind-mesh1"
PAT="${GITHUB_PAT:-${GITHUB_PORTLAB_TOKEN:-}}"
[ -n "$PAT" ] || { echo "✗ set GITHUB_PAT (a GitHub PAT; read access is enough)"; exit 1; }

echo "== make sure the cluster can resolve its own ingress names =="
"$HERE/fix-cluster-dns.sh" >/dev/null 2>&1 || echo "  (dns fix skipped)"

LB="$($K -n agentgateway-system get gateway ar-ingress -o jsonpath='{.status.addresses[0].value}')"
[ -n "$LB" ] || { echo "✗ no ar-ingress address — is the Part 4 platform up?"; exit 1; }
echo "== ar-ingress at $LB =="

echo "== the PAT, in ONE Secret that only the gateway reads =="
$K -n agentgateway-system create secret generic github-mcp-pat \
  --from-literal=Authorization="$PAT" --dry-run=client -o yaml | $K apply -f -

echo "== agentgateway fronts GitHub's hosted MCP server (ingress, for steps 1 and 2) =="
sed "s/LB_PLACEHOLDER/$LB/" "$HERE/../yaml/10-github-backend.yaml" | $K apply -f -

echo "== and again at a WAYPOINT in the mesh, which is what the agents use =="
# The PAT has to exist where the waypoint can read it, so it goes in both namespaces.
# The waypoint is the only enforcement point that sees the calling agent's identity.
$K -n kagent create secret generic github-mcp-pat \
  --from-literal=Authorization="$PAT" --dry-run=client -o yaml | $K apply -f -
$K apply -f "$HERE/../yaml/15-github-waypoint.yaml"

echo "== register it in the catalogue, pointing at the GATEWAY =="
sed "s/LB_PLACEHOLDER/$LB/" "$HERE/../yaml/30-mcpserver-github.yaml" > /tmp/ar-github-mcp.yaml
arctl apply -f /tmp/ar-github-mcp.yaml

echo "== register the approved release-report skill =="
arctl apply -f "$HERE/../skill/release-report/skill.yaml"

echo
echo "== wait for the waypoint to be Programmed =="
prog=""
for _ in $(seq 1 45); do
  prog="$($K -n kagent get gateway github-mcp-waypoint \
          -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  [ "$prog" = "True" ] && break
  sleep 2
done
if [ "$prog" != "True" ]; then
  echo "✗ the github-mcp waypoint is not Programmed after 90s (status='${prog:-<none>}')"
  $K -n kagent get gateway github-mcp-waypoint -o yaml | sed -n '/status:/,$p' | head -20
  exit 1
fi
echo "waypoint Programmed=True"
echo

echo "== wait for the backend to be Accepted =="
st=""
for _ in $(seq 1 30); do
  st="$($K -n agentgateway-system get enterpriseagentgatewaybackend github-mcp \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  [ "$st" = "True" ] && break
  sleep 2
done
# Do not print success for whatever the loop happened to leave in $st. An unaccepted
# backend fails later, in the middle of the demo, with a much less obvious message.
if [ "$st" != "True" ]; then
  echo "✗ the github-mcp backend is not Accepted after 60s (status='${st:-<none>}')"
  $K -n agentgateway-system get enterpriseagentgatewaybackend github-mcp \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null
  exit 1
fi
echo "backend Accepted=True"
echo
echo "✓ Part 8 ready."
echo "    agents call:  http://github-mcp.kagent.svc.cluster.local/   (waypoint, identity-aware)"
echo "    laptop calls: http://github-mcp.${LB}.sslip.io/              (ingress, steps 1 and 2)"
